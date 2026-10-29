import SectorCore
import SwiftUI

/// Rings view of the disk map: a `Canvas` sunburst drawn from precomputed
/// geometry, hover and clicks resolved with polar math, and a center disk
/// that names the focus or the hovered item.
struct SunburstChart: View {
  @Environment(AppModel.self) private var app
  let explorer: ExplorerModel
  @State private var appear: Double = 0

  var body: some View {
    GeometryReader { geo in
      let side = min(geo.size.width, geo.size.height)
      let rings = SunburstRings(radius: max(60, side / 2 - 18))
      let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
      ZStack {
        SunburstCanvas(
          layout: explorer.rings ?? .empty, zoom: explorer.zoom, progress: explorer.zoomProgress,
          appear: appear, dim: explorer.hover == nil ? 0 : 1, hover: explorer.hover?.index,
          palette: ExplorerPalette(breakdown: app.breakdown), rings: rings, center: center
        )
        .animation(Motion.resolve(Motion.quick), value: explorer.hover?.index)

        SunburstCenter(explorer: explorer, diameter: max(40, (rings.hole - 8) * 2))
          .position(center)
      }
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        switch phase {
        case .active(let point):
          let hit = hitTest(point, rings: rings, center: center)
          if hit != explorer.hover { explorer.hover = hit }
        case .ended:
          if explorer.hover != nil { explorer.hover = nil }
        }
      }
      .onTapGesture { point in
        guard let hit = hitTest(point, rings: rings, center: center) else { return }
        explorer.activate(node: hit.node, isOther: hit.isOther)
      }
      .pointerStyle(isZoomable(explorer.hover) ? .zoomIn : nil)
      .contextMenu { ExplorerContextMenu(explorer: explorer) }
    }
    .onAppear {
      if Motion.reduced {
        appear = 1
      } else {
        withAnimation(.linear(duration: 1.5)) { appear = 1 }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Диаграмма папки")
  }

  private func hitTest(_ point: CGPoint, rings: SunburstRings, center: CGPoint) -> ExplorerHover? {
    guard explorer.zoom == nil, let layout = explorer.rings else { return nil }
    let dx = Double(point.x - center.x)
    let dy = Double(point.y - center.y)
    guard let ring = rings.ring(at: (dx * dx + dy * dy).squareRoot()) else { return nil }
    let fraction = SunburstRings.fraction(dx: dx, dy: dy)
    guard let i = layout.segment(depth: ring, at: fraction) else { return nil }
    let s = layout.segments[i]
    return ExplorerHover(
      index: i, node: s.node, isOther: s.isOther, size: s.size, otherCount: s.otherCount)
  }

  private func isZoomable(_ hover: ExplorerHover?) -> Bool {
    guard let hover, let tree = app.tree else { return false }
    return hover.isOther ? hover.node != explorer.focus : tree.isDirectory(hover.node)
  }
}

/// The disk in the middle: focus (or hovered item) name and size; clicking
/// it goes up a level.
private struct SunburstCenter: View {
  @Environment(AppModel.self) private var app
  let explorer: ExplorerModel
  let diameter: CGFloat
  @State private var shown = false

  var body: some View {
    let content = self.content
    let parts = ByteFormat.parts(content.size)
    Button {
      explorer.goUp()
    } label: {
      VStack(spacing: 1) {
        Text(content.title)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: diameter * 0.78)
        Text(parts.number)
          .font(.system(size: min(30, diameter * 0.18), weight: .bold))
          .monospacedDigit()
          .contentTransition(.numericText())
        if content.showsBack {
          HStack(spacing: 3) {
            Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
            Text("Назад")
          }
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.sectorAccent)
        } else {
          Text("\(parts.unit) · \(content.hint)")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: diameter * 0.8)
        }
      }
      .frame(width: diameter, height: diameter)
      .background {
        Circle()
          .fill(.background.opacity(0.9))
          .shadow(color: .black.opacity(0.12), radius: 15, y: 10)
      }
      .overlay(Circle().strokeBorder(Color.sectorHairline, lineWidth: 0.5))
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .animation(Motion.resolve(Motion.quick), value: content)
    .scaleEffect(shown ? 1 : 0.6)
    .opacity(shown ? 1 : 0)
    .onAppear {
      withAnimation(Motion.resolve(Motion.bouncy).delay(Motion.reduced ? 0 : 0.1)) { shown = true }
    }
    .accessibilityLabel(Text("\(content.title), \(ByteFormat.string(content.size))"))
  }

  private struct Content: Equatable {
    var title: String
    var size: UInt64
    var hint: String
    var showsBack: Bool
  }

  private var content: Content {
    guard let tree = app.tree else {
      return Content(title: "", size: 0, hint: "", showsBack: false)
    }
    if let hover = explorer.hover {
      if hover.isOther {
        return Content(
          title: String(localized: "Прочее"), size: hover.size,
          hint: Plural.format(hover.otherCount, "объект", "объекта", "объектов"), showsBack: false)
      }
      let isDir = tree.isDirectory(hover.node)
      return Content(
        title: tree.name(hover.node), size: hover.size,
        hint: isDir ? String(localized: "нажмите, чтобы открыть") : String(localized: "файл"),
        showsBack: false)
    }
    let focus = explorer.focus
    let title = explorer.crumbs.last?.name ?? tree.name(focus)
    return Content(
      title: title, size: tree.size(focus), hint: String(localized: "занято"),
      showsBack: focus != FileTree.root)
  }
}

/// Draws the sunburst. Animatable so SwiftUI interpolates the zoom,
/// entrance and hover-dim values frame by frame; nothing here allocates a
/// view per segment.
struct SunburstCanvas: View, Animatable {
  var layout: SunburstLayout
  var zoom: ExplorerZoom?
  var progress: Double
  var appear: Double
  var dim: Double
  var hover: Int?
  var palette: ExplorerPalette
  var rings: SunburstRings
  var center: CGPoint

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
      let renderer = SunburstRenderer(
        context: context, rings: rings, center: center, palette: palette, appear: appear)
      if let zoom {
        let t = zoom.position(progress)
        let s0 = zoom.spanStart
        let s1 = zoom.spanEnd
        let w0 = t * s0
        let w1 = 1 + t * (s1 - 1)
        let width = max(1e-9, w1 - w0)
        let shift = t * Double(zoom.depth + 1)
        renderer.draw(
          zoom.outerRings,
          pass: .init(
            scale: 1 / width, offset: -w0 / width, depthOffset: -shift, alpha: 1 - t,
            skip: (s0, s1, zoom.depth)),
          hover: nil, dim: 0)
        renderer.draw(
          zoom.innerRings,
          pass: .init(
            scale: (s1 - s0) / width, offset: (s0 - w0) / width,
            depthOffset: Double(zoom.depth + 1) - shift, alpha: 1, skip: nil),
          hover: nil, dim: 0)
      } else {
        renderer.draw(layout, pass: .identity, hover: hover, dim: dim)
      }
    }
  }
}

/// One drawing pass of the sunburst renderer.
private struct SunburstPass {
  /// Maps a layout angle `a` to the screen fraction `a * scale + offset`.
  var scale: Double
  var offset: Double
  /// Added to every segment's ring index.
  var depthOffset: Double
  var alpha: Double
  /// Segments inside this arc and deeper than `depth` are skipped (the
  /// inner layout draws them during a zoom).
  var skip: (start: Double, end: Double, depth: Int)?

  static let identity = SunburstPass(scale: 1, offset: 0, depthOffset: 0, alpha: 1, skip: nil)
}

private struct SunburstRenderer {
  var context: GraphicsContext
  var rings: SunburstRings
  var center: CGPoint
  var palette: ExplorerPalette
  var appear: Double

  func draw(_ layout: SunburstLayout, pass: SunburstPass, hover: Int?, dim: Double) {
    let hover = hover.flatMap { layout.segments.indices.contains($0) ? $0 : nil }
    let ringCount = Double(rings.ringCount)
    let twoPi = 2 * Double.pi
    let entering = appear < 1
    for i in layout.segments.indices {
      let s = layout.segments[i]
      if let skip = pass.skip, s.depth > skip.depth, s.start >= skip.start - 1e-9,
        s.end <= skip.end + 1e-9
      {
        continue
      }
      var a0 = s.start * pass.scale + pass.offset
      var a1 = s.end * pass.scale + pass.offset
      if a1 <= 0 || a0 >= 1 { continue }
      a0 = max(0, a0)
      a1 = min(1, a1)
      let p = Double(s.depth) + pass.depthOffset
      if p >= ringCount || p <= -1 { continue }
      var alpha = pass.alpha * ExplorerEase.clamp(p + 1) * ExplorerEase.clamp(ringCount - p)
      var radiusScale = 1.0

      if entering {
        let local = ExplorerEase.local(
          appear * 1.5, delay: Double(s.depth) * 0.12 + a0 * 0.35, duration: 0.7)
        if local <= 0 { continue }
        let e = ExplorerEase.backOut(local)
        let turn = (1 - e) * 0.11
        a0 -= turn
        a1 -= turn
        radiusScale = 0.7 + 0.3 * e
        alpha *= min(1, local * 2)
      }

      if let hover {
        if i == hover {
          radiusScale *= 1 + 0.035 * dim
        } else if !layout.isWithin(i, hover) && !layout.isWithin(hover, i) {
          alpha *= 1 - 0.7 * dim
        }
      }
      if alpha < 0.01 { continue }

      var r0 = rings.radius(p) * radiusScale
      var r1 = rings.radius(p + 1) * radiusScale
      if r1 - r0 > 4 {
        r0 += 1
        r1 -= 1
      }
      guard r1 > r0, r1 > 1 else { continue }
      if (a1 - a0) * twoPi * r1 > 4 {
        let pad = 1 / (twoPi * r1)
        a0 += pad
        a1 -= pad
      }
      a1 = min(a1, a0 + 0.99999)

      let color: Color =
        s.isOther
        ? ExplorerPalette.other
        : palette.color(s.node, level: Int(max(0, p).rounded()), parity: s.siblingIndex)
      var c = context
      c.opacity = alpha
      c.fill(sector(r0: r0, r1: r1, a0: a0, a1: a1), with: .color(color))
    }
  }

  /// Annular sector between radii `r0`…`r1` and angle fractions `a0`…`a1`
  /// (clockwise from twelve o'clock).
  private func sector(r0: Double, r1: Double, a0: Double, a1: Double) -> Path {
    let start = Angle.radians(a0 * 2 * .pi - .pi / 2)
    let end = Angle.radians(a1 * 2 * .pi - .pi / 2)
    var path = Path()
    path.addArc(center: center, radius: r1, startAngle: start, endAngle: end, clockwise: false)
    path.addArc(
      center: center, radius: max(0, r0), startAngle: end, endAngle: start, clockwise: true)
    path.closeSubpath()
    return path
  }
}
