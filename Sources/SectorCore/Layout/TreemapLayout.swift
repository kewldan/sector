import CoreGraphics
import Foundation

/// Squarified treemap (Bruls, Huizing, van Wijk): rows of rectangles whose
/// aspect ratios stay close to 1.
public enum Squarify {
  /// Rectangles for `values` (largest first works best) filling `rect` in
  /// proportion. Zero or negative values get empty rectangles.
  public static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
    var result = [CGRect](repeating: .zero, count: values.count)
    let total = values.reduce(0) { $0 + max(0, $1) }
    guard total > 0, rect.width > 0, rect.height > 0 else { return result }
    let scale = Double(rect.width * rect.height) / total
    let areas = values.map { max(0, $0) * scale }

    var free = rect
    var start = 0
    while start < areas.count {
      let side = Double(min(free.width, free.height))
      guard side > 0 else { break }
      var end = start + 1
      var rowSum = areas[start]
      var best = worst(areas[start..<end], sum: rowSum, side: side)
      while end < areas.count {
        let nextSum = rowSum + areas[end]
        let candidate = worst(areas[start...end], sum: nextSum, side: side)
        if candidate > best { break }
        best = candidate
        rowSum = nextSum
        end += 1
      }
      // The last row takes whatever is left so rounding never leaves a gap.
      let isLast = end == areas.count
      if free.width >= free.height {
        let width = isLast ? Double(free.width) : (rowSum / Double(free.height))
        var y = Double(free.minY)
        for i in start..<end {
          let h = rowSum > 0 ? areas[i] / rowSum * Double(free.height) : 0
          result[i] = CGRect(x: Double(free.minX), y: y, width: width, height: h)
          y += h
        }
        free = CGRect(
          x: free.minX + width, y: free.minY, width: max(0, free.width - width),
          height: free.height)
      } else {
        let height = isLast ? Double(free.height) : (rowSum / Double(free.width))
        var x = Double(free.minX)
        for i in start..<end {
          let w = rowSum > 0 ? areas[i] / rowSum * Double(free.width) : 0
          result[i] = CGRect(x: x, y: Double(free.minY), width: w, height: height)
          x += w
        }
        free = CGRect(
          x: free.minX, y: free.minY + height, width: free.width,
          height: max(0, free.height - height))
      }
      start = end
    }
    return result
  }

  /// Worst aspect ratio of a row laid along a side of length `side`.
  private static func worst(_ row: ArraySlice<Double>, sum: Double, side: Double) -> Double {
    guard sum > 0, let maxArea = row.max(), let minArea = row.min(), minArea > 0 else {
      return .infinity
    }
    let s2 = sum * sum
    let w2 = side * side
    return max(w2 * maxArea / s2, s2 / (w2 * minArea))
  }
}

/// Two levels of a folder's contents prepared for the treemap: sorted,
/// named and with long tails merged, so laying out for a new size needs no
/// tree access.
public struct TreemapSource: Sendable {
  public struct Entry: Sendable, Hashable {
    /// The node, or for an "other" entry the parent it belongs to.
    public var node: NodeID
    public var name: String
    public var size: UInt64
    public var isDirectory: Bool
    public var isOther: Bool
    public var otherCount: Int
    public var children: [Entry]
  }

  public var root: NodeID
  public var total: UInt64
  public var entries: [Entry]

  /// Reads `root`'s children (up to `limit`) and the children of the
  /// largest `expandLimit` of them (up to `childLimit` each).
  public static func make(
    tree: FileTree, root: NodeID, limit: Int = 240, childLimit: Int = 64, expandLimit: Int = 48
  ) -> TreemapSource {
    func entries(of id: NodeID, limit: Int, expand: Int) -> [Entry] {
      let children = tree.orderedChildren(id)
      var result: [Entry] = []
      for (i, child) in children.prefix(limit).enumerated() {
        let isDir = tree.isDirectory(child)
        let sub = isDir && i < expand ? entries(of: child, limit: childLimit, expand: 0) : []
        result.append(
          Entry(
            node: child, name: tree.name(child), size: tree.size(child), isDirectory: isDir,
            isOther: false, otherCount: 0, children: sub))
      }
      if children.count > limit {
        var rest: UInt64 = 0
        for child in children[limit...] { rest &+= tree.size(child) }
        result.append(
          Entry(
            node: id, name: "", size: rest, isDirectory: false, isOther: true,
            otherCount: children.count - limit, children: []))
      }
      return result
    }
    return TreemapSource(
      root: root, total: tree.size(root),
      entries: entries(of: root, limit: limit, expand: expandLimit))
  }
}

/// One rectangle of a treemap.
public struct TreemapTile: Sendable, Hashable {
  public var node: NodeID
  public var parent: Int32
  /// 0 for the focus folder's children, 1 inside a group.
  public var depth: Int
  public var rect: CGRect
  public var size: UInt64
  public var name: String
  public var isDirectory: Bool
  public var isOther: Bool
  public var otherCount: Int
  /// A group frames its children under a header instead of being filled.
  public var isGroup: Bool
  public var siblingIndex: Int
}

/// A laid-out treemap for one size. Groups precede their children, so a
/// reverse scan finds the deepest tile under a point.
public struct TreemapLayout: Sendable {
  public let root: NodeID
  public let bounds: CGRect
  public let tiles: [TreemapTile]

  public static let headerHeight: CGFloat = 22

  /// - Parameters:
  ///   - gap: space between neighbouring tiles.
  ///   - minSide: tiles whose area would fall below `minSide²` merge into
  ///     one "other" tile.
  public static func make(
    source: TreemapSource, bounds: CGRect, gap: CGFloat = 4, minSide: CGFloat = 18
  ) -> TreemapLayout {
    var tiles: [TreemapTile] = []
    place(
      source.entries, in: bounds, depth: 0, parent: -1, owner: source.root, gap: gap,
      minArea: Double(minSide * minSide), tiles: &tiles)
    return TreemapLayout(root: source.root, bounds: bounds, tiles: tiles)
  }

  public init(root: NodeID, bounds: CGRect, tiles: [TreemapTile]) {
    self.root = root
    self.bounds = bounds
    self.tiles = tiles
  }

  private static func place(
    _ entries: [TreemapSource.Entry], in rect: CGRect, depth: Int, parent: Int32, owner: NodeID,
    gap: CGFloat, minArea: Double, tiles: inout [TreemapTile]
  ) {
    let total = entries.reduce(0.0) { $0 + Double($1.size) }
    guard total > 0, rect.width > 1, rect.height > 1 else { return }
    let area = Double(rect.width * rect.height)

    // Merge the tail that would be too small to see.
    var items = entries
    if let cut = items.firstIndex(where: { Double($0.size) / total * area < minArea }),
      items.count - cut >= 2
    {
      let tail = items[cut...]
      let merged = TreemapSource.Entry(
        node: owner, name: "", size: tail.reduce(0) { $0 + $1.size }, isDirectory: false,
        isOther: true, otherCount: tail.reduce(0) { $0 + ($1.isOther ? $1.otherCount : 1) },
        children: [])
      items.removeSubrange(cut...)
      if let last = items.last, last.isOther {
        items[items.count - 1].size += merged.size
        items[items.count - 1].otherCount += merged.otherCount
      } else {
        items.append(merged)
      }
    }

    let rects = Squarify.layout(items.map { Double($0.size) }, in: rect)
    for (i, entry) in items.enumerated() {
      let r = rects[i].insetBy(dx: gap / 2, dy: gap / 2)
      guard r.width > 0.5, r.height > 0.5 else { continue }
      let canGroup =
        depth == 0 && !entry.children.isEmpty && r.width >= 72 && r.height >= headerHeight + 40
      let index = Int32(tiles.count)
      tiles.append(
        TreemapTile(
          node: entry.node, parent: parent, depth: depth, rect: r, size: entry.size,
          name: entry.name, isDirectory: entry.isDirectory, isOther: entry.isOther,
          otherCount: entry.otherCount, isGroup: canGroup, siblingIndex: i))
      if canGroup {
        let inner = CGRect(
          x: r.minX + 3, y: r.minY + headerHeight, width: r.width - 6,
          height: r.height - headerHeight - 3)
        place(
          entry.children, in: inner, depth: depth + 1, parent: index, owner: entry.node,
          gap: gap * 0.75, minArea: minArea * 0.6, tiles: &tiles)
      }
    }
  }

  /// Deepest tile under `point`.
  public func hit(_ point: CGPoint) -> Int? {
    for i in tiles.indices.reversed() where tiles[i].rect.contains(point) { return i }
    return nil
  }

  /// Tile drawing `node` (not an "other" tile).
  public func index(of node: NodeID) -> Int? {
    tiles.firstIndex { $0.node == node && !$0.isOther }
  }

  /// Whether tile `i` is `ancestor` or one of its children.
  public func isWithin(_ i: Int, _ ancestor: Int) -> Bool {
    var cur = Int32(i)
    while cur >= 0 {
      if Int(cur) == ancestor { return true }
      cur = tiles[Int(cur)].parent
    }
    return false
  }
}
