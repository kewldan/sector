import SectorCore
import SwiftUI

/// Tiles view of the disk map: a squarified treemap of the focus folder's
/// children (grouped with their own children), drawn in one `Canvas`.
struct TreemapChart: View {
  @Environment(AppModel.self) private var app
  let explorer: ExplorerModel
  @State private var appear: Double = 0
  @State private var cache = TreemapLayoutCache()

  var body: some View {
    GeometryReader { geo in
      let bounds = CGRect(origin: .zero, size: geo.size).insetBy(dx: 14, dy: 14)
      let current = explorer.tiles.map { cache.layout($0, bounds: bounds) }
      let zoom = explorer.zoom.map { zoomGeometry($0, bounds: bounds) }
      TreemapCanvas(
        layout: current, zoom: zoom, progress: explorer.zoomProgress, appear: appear,
        dim: explorer.hover == nil ? 0 : 1, hover: explorer.hover?.index,
        palette: ExplorerPalette(breakdown: app.breakdown)
      )
      .animation(Motion.resolve(Motion.quick), value: explorer.hover?.index)
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        switch phase {
        case .active(let point):
          let hit = hitTest(point, layout: current)
          if hit != explorer.hover { explorer.hover = hit }
        case .ended:
          if explorer.hover != nil { explorer.hover = nil }
        }
      }
      .onTapGesture { point in
        guard let hit = hitTest(point, layout: current) else { return }
        explorer.activate(node: hit.node, isOther: hit.isOther)
      }
      .pointerStyle(isZoomable(explorer.hover) ? .zoomIn : nil)
      .contextMenu { ExplorerContextMenu(explorer: explorer) }
    }
    .onAppear {
      if Motion.reduced {
        appear = 1
      } else {
        withAnimation(.linear(duration: 1.2)) { appear = 1 }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Плитки папки")
  }

  private func zoomGeometry(_ zoom: ExplorerZoom, bounds: CGRect) -> TreemapZoom {
    let outer = cache.layout(zoom.outerTiles, bounds: bounds)
    let inner = cache.layout(zoom.innerTiles, bounds: bounds)
    // Zoom from the deepest tile of the inner folder's lineage the outer
    // treemap drew; with none, the views simply crossfade.
    var anchor: Int?
    for node in zoom.innerLineage {
      if let i = outer.index(of: node) {
        anchor = i
        break
      }
    }
    return TreemapZoom(
      outer: outer, inner: inner, anchor: anchor,
      rect: anchor.map { outer.tiles[$0].rect } ?? bounds, zoomingIn: zoom.zoomingIn)
  }

  private func hitTest(_ point: CGPoint, layout: TreemapLayout?) -> ExplorerHover? {
    guard explorer.zoom == nil, let layout, let i = layout.hit(point) else { return nil }
    let tile = layout.tiles[i]
    return ExplorerHover(
      index: i, node: tile.node, isOther: tile.isOther, size: tile.size,
      otherCount: tile.otherCount)
  }

  private func isZoomable(_ hover: ExplorerHover?) -> Bool {
    guard let hover, let tree = app.tree else { return false }
    return hover.isOther ? hover.node != explorer.focus : tree.isDirectory(hover.node)
  }
}

/// Remembers recent layouts so hover redraws and zoom frames never redo
/// the squarify pass.
@MainActor
final class TreemapLayoutCache {
  private var entries: [(root: NodeID, total: UInt64, bounds: CGRect, layout: TreemapLayout)] = []

  func layout(_ source: TreemapSource, bounds: CGRect) -> TreemapLayout {
    if let hit = entries.first(where: {
      $0.root == source.root && $0.total == source.total && $0.bounds == bounds
    }) {
      return hit.layout
    }
    let layout = TreemapLayout.make(source: source, bounds: bounds)
    entries.append((source.root, source.total, bounds, layout))
    if entries.count > 6 { entries.removeFirst() }
    return layout
  }
}

/// Treemap geometry of a zoom transition.
struct TreemapZoom: Sendable {
  var outer: TreemapLayout
  var inner: TreemapLayout
  /// Tile of the outer layout the inner folder grows out of.
  var anchor: Int?
  var rect: CGRect
  var zoomingIn: Bool

  func position(_ progress: Double) -> Double {
    let p = ExplorerEase.clamp(progress)
    return zoomingIn ? p : 1 - p
  }
}

struct TreemapCanvas: View, Animatable {
  var layout: TreemapLayout?
  var zoom: TreemapZoom?
  var progress: Double
  var appear: Double
  var dim: Double
  var hover: Int?
  var palette: ExplorerPalette

  nonisolated var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
    get { AnimatablePair(progress, AnimatablePair(appear, dim)) }
    set {
      progress = newValue.first
      appear = newValue.second.first
      dim = newValue.second.second
    }
  }

  var body: some View {
    Canvas { context, _ in
      let renderer = TreemapRenderer(context: context, palette: palette, appear: appear)
      if let zoom {
        let t = zoom.position(progress)
        let from = zoom.rect
        let bounds = zoom.inner.bounds
        let now = CGRect(
          x: lerp(from.minX, bounds.minX, t), y: lerp(from.minY, bounds.minY, t),
          width: lerp(from.width, bounds.width, t), height: lerp(from.height, bounds.height, t))
        let outerMap = RectMap(from: from, to: now)
        let innerMap = RectMap(from: bounds, to: now)
        let fadeOut = 1 - ExplorerEase.clamp(t * 3)
        renderer.draw(
          zoom.outer, map: outerMap,
          alpha: { i in
            if let anchor = zoom.anchor, zoom.outer.isWithin(i, anchor) { return fadeOut }
            return 1 - t
          }, hover: nil, dim: 0)
        let fadeIn = zoom.anchor == nil ? t : ExplorerEase.clamp(t * 3)
        renderer.draw(zoom.inner, map: innerMap, alpha: { _ in fadeIn }, hover: nil, dim: 0)
      } else if let layout {
        renderer.draw(layout, map: .identity, alpha: { _ in 1 }, hover: hover, dim: dim)
      }
    }
  }

  private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
    a + (b - a) * CGFloat(t)
  }
}

/// Affine map taking rectangle `from` onto `to`.
private struct RectMap {
  var from: CGRect
  var to: CGRect

  static let identity = RectMap(
    from: CGRect(x: 0, y: 0, width: 1, height: 1), to: CGRect(x: 0, y: 0, width: 1, height: 1))

  func apply(_ r: CGRect) -> CGRect {
    guard from.width > 0, from.height > 0 else { return r }
    let sx = to.width / from.width
    let sy = to.height / from.height
    return CGRect(
      x: to.minX + (r.minX - from.minX) * sx, y: to.minY + (r.minY - from.minY) * sy,
      width: r.width * sx, height: r.height * sy)
  }
}

private struct TreemapRenderer {
  var context: GraphicsContext
  var palette: ExplorerPalette
  var appear: Double

  private static let maxLabels = 140

  func draw(
    _ layout: TreemapLayout, map: RectMap, alpha: (Int) -> Double, hover: Int?, dim: Double
  ) {
    let hover = hover.flatMap { layout.tiles.indices.contains($0) ? $0 : nil }
    var labels: [(index: Int, rect: CGRect, alpha: Double)] = []
    let entering = appear < 1

    for i in layout.tiles.indices {
      let tile = layout.tiles[i]
      var a = alpha(i)
      if a < 0.01 { continue }
      var rect = map.apply(tile.rect)

      if entering {
        let local = ExplorerEase.local(
          appear * 1.2, delay: min(0.45, Double(i) * 0.008) + Double(tile.depth) * 0.12,
          duration: 0.6)
        if local <= 0 { continue }
        let s = 0.85 + 0.15 * ExplorerEase.backOut(local)
        rect = rect.insetBy(dx: rect.width * (1 - s) / 2, dy: rect.height * (1 - s) / 2)
        a *= min(1, local * 2)
      }
      let hovered = hover == i
      if hovered {
        let s = 1 - 0.015 * dim
        rect = rect.insetBy(dx: rect.width * (1 - s) / 2, dy: rect.height * (1 - s) / 2)
      }
      guard rect.width > 0.5, rect.height > 0.5 else { continue }

      let radius = min(tile.depth == 0 ? 12 : 9, rect.width / 3, rect.height / 3)
      let shape = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
      var c = context
      c.opacity = a
      if tile.isGroup {
        c.fill(
          shape, with: .color(palette.base(tile.node).opacity(hovered ? 0.2 + 0.06 * dim : 0.13)))
      } else {
        let color =
          tile.isOther
          ? ExplorerPalette.other
          : palette.color(tile.node, level: tile.depth, parity: tile.siblingIndex)
        c.fill(shape, with: .color(color))
        if hovered && dim > 0 {
          c.fill(shape, with: .color(.white.opacity(0.16 * dim)))
        }
      }
      let labelable =
        tile.isGroup
        ? rect.width >= 60
        : rect.width >= 52 && rect.height >= 30
      if labelable && labels.count < Self.maxLabels { labels.append((i, rect, a)) }
    }

    for label in labels {
      drawLabel(layout.tiles[label.index], in: label.rect, alpha: label.alpha)
    }
  }

  private func drawLabel(_ tile: TreemapTile, in rect: CGRect, alpha: Double) {
    let name = tile.isOther ? String(localized: "Прочее") : tile.name
    let size = ByteFormat.string(tile.size)
    var c = context
    c.opacity = alpha
    if tile.isGroup {
      let header = CGRect(
        x: rect.minX, y: rect.minY, width: rect.width, height: TreemapLayout.headerHeight)
      c.clip(to: Path(header))
      let sizeText = Text(size).font(.system(size: 11)).foregroundStyle(.secondary)
        .monospacedDigit()
      let sizeWidth = c.resolve(sizeText).measure(in: header.size).width
      let available = header.width - sizeWidth - 26
      if available > 20 {
        let title = Text(Self.truncate(name, width: available, fontSize: 11))
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(palette.base(tile.node))
        c.draw(title, at: CGPoint(x: rect.minX + 9, y: rect.minY + 5), anchor: .topLeading)
      }
      c.draw(sizeText, at: CGPoint(x: rect.maxX - 9, y: rect.minY + 5), anchor: .topTrailing)
      return
    }
    c.clip(to: Path(rect))
    let width = rect.width - 18
    let title = Self.truncate(name, width: width, fontSize: 12)
    let showsSize = rect.height >= 44
    let titleY = showsSize ? rect.maxY - 22 : rect.maxY - 7
    let origin = CGPoint(x: rect.minX + 9, y: titleY)
    // A faint shadow keeps white text legible on light tints.
    c.draw(
      Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.black.opacity(0.22)),
      at: CGPoint(x: origin.x, y: origin.y + 0.8), anchor: .bottomLeading)
    c.draw(
      Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white),
      at: origin, anchor: .bottomLeading)
    if showsSize {
      c.draw(
        Text(size).font(.system(size: 11)).foregroundStyle(.white.opacity(0.9)).monospacedDigit(),
        at: CGPoint(x: rect.minX + 9, y: rect.maxY - 7), anchor: .bottomLeading)
    }
  }

  /// Cuts `text` to roughly fit `width` points, ending with "…".
  static func truncate(_ text: String, width: CGFloat, fontSize: CGFloat) -> String {
    let maxChars = Int(width / (fontSize * 0.56))
    guard text.count > maxChars else { return text }
    guard maxChars > 2 else { return "" }
    return String(text.prefix(maxChars - 1)) + "…"
  }
}
