import Foundation

/// One arc of a sunburst ring. Angles are fractions of the full circle,
/// measured clockwise from twelve o'clock.
public struct SunburstSegment: Sendable, Hashable {
  /// The node drawn, or for an "other" segment the parent whose small
  /// children it merges.
  public var node: NodeID
  /// Index of the parent segment, -1 for the innermost ring.
  public var parent: Int32
  /// Ring index, 0 for the focus folder's direct children.
  public var depth: Int
  public var start: Double
  public var end: Double
  public var size: UInt64
  /// True for the merged "Прочее" arc.
  public var isOther: Bool
  /// Number of items merged into an "other" arc.
  public var otherCount: Int
  /// Position among its siblings, for alternating tints.
  public var siblingIndex: Int

  public var span: Double { end - start }
}

/// Precomputed sunburst geometry for one focus folder. Rings are stored
/// contiguously and sorted by angle, so hit-testing is a binary search and
/// drawing is a flat loop.
public struct SunburstLayout: Sendable {
  public let root: NodeID
  public let total: UInt64
  public let maxDepth: Int
  public let segments: [SunburstSegment]
  /// Segment index range of every ring, innermost first.
  public let rings: [Range<Int>]

  public static let empty = SunburstLayout(
    root: FileTree.root, total: 0, maxDepth: 0, segments: [], rings: [])

  public init(
    root: NodeID, total: UInt64, maxDepth: Int, segments: [SunburstSegment], rings: [Range<Int>]
  ) {
    self.root = root
    self.total = total
    self.maxDepth = maxDepth
    self.segments = segments
    self.rings = rings
  }

  /// Lays out up to `maxDepth` rings below `root`. Children narrower than
  /// `minSpan` (a fraction of the circle) are merged into one "other" arc
  /// per parent, which bounds the segment count whatever the tree size.
  public static func make(
    tree: FileTree, root: NodeID, maxDepth: Int = 5, minSpan: Double = 0.0035
  ) -> SunburstLayout {
    let total = tree.size(root)
    guard total > 0, maxDepth > 0 else {
      return SunburstLayout(root: root, total: total, maxDepth: maxDepth, segments: [], rings: [])
    }
    let scale = 1 / Double(total)
    var segments: [SunburstSegment] = []
    var rings: [Range<Int>] = []
    // Directories whose children form the next ring: node, start angle and
    // parent segment index.
    var level: [(node: NodeID, start: Double, segment: Int32)] = [(root, 0, -1)]

    for depth in 0..<maxDepth {
      let ringStart = segments.count
      var next: [(node: NodeID, start: Double, segment: Int32)] = []
      for item in level {
        let children = tree.orderedChildren(item.node)
        var cursor = item.start
        var index = 0
        while index < children.count {
          let child = children[index]
          let size = tree.size(child)
          let span = Double(size) * scale
          if span < minSpan { break }
          let segmentIndex = Int32(segments.count)
          segments.append(
            SunburstSegment(
              node: child, parent: item.segment, depth: depth, start: cursor,
              end: cursor + span, size: size, isOther: false, otherCount: 0, siblingIndex: index))
          if tree.isDirectory(child) && depth + 1 < maxDepth {
            next.append((child, cursor, segmentIndex))
          }
          cursor += span
          index += 1
        }
        // A folder whose children are all too small reads as a leaf; only
        // folders with visible children get a merged "other" arc.
        if (index > 0 || depth == 0) && index < children.count {
          var rest: UInt64 = 0
          for child in children[index...] { rest &+= tree.size(child) }
          let span = Double(rest) * scale
          if span >= minSpan * 0.5 {
            segments.append(
              SunburstSegment(
                node: item.node, parent: item.segment, depth: depth, start: cursor,
                end: cursor + span, size: rest, isOther: true, otherCount: children.count - index,
                siblingIndex: index))
          }
        }
      }
      guard segments.count > ringStart else { break }
      rings.append(ringStart..<segments.count)
      level = next
      if level.isEmpty { break }
    }
    return SunburstLayout(
      root: root, total: total, maxDepth: maxDepth, segments: segments, rings: rings)
  }

  /// Segment of ring `depth` under the angle `fraction` (0..<1), if any.
  public func segment(depth: Int, at fraction: Double) -> Int? {
    guard rings.indices.contains(depth) else { return nil }
    let ring = rings[depth]
    var lo = ring.lowerBound
    var hi = ring.upperBound
    // Last segment whose start is <= fraction.
    while lo < hi {
      let mid = (lo + hi) / 2
      if segments[mid].start <= fraction { lo = mid + 1 } else { hi = mid }
    }
    let candidate = lo - 1
    guard candidate >= ring.lowerBound else { return nil }
    let s = segments[candidate]
    return fraction < s.end ? candidate : nil
  }

  /// Index of the (non-"other") segment that draws `node`.
  public func index(of node: NodeID) -> Int? {
    segments.firstIndex { $0.node == node && !$0.isOther }
  }

  /// Whether segment `i` is `ancestor` or lies inside its arc.
  public func isWithin(_ i: Int, _ ancestor: Int) -> Bool {
    var cur = Int32(i)
    while cur >= 0 {
      if Int(cur) == ancestor { return true }
      cur = segments[Int(cur)].parent
    }
    return false
  }

  /// Exact arc of `node` inside a sunburst rooted at `root`, even when the
  /// layout merged it away or it lies deeper than the drawn rings. `depth`
  /// is its ring index (0 for a direct child of `root`).
  public static func span(
    of node: NodeID, under root: NodeID, in tree: FileTree
  ) -> (start: Double, end: Double, depth: Int)? {
    guard node != root, tree.isDescendant(node, of: root) else { return nil }
    let total = tree.size(root)
    guard total > 0 else { return nil }
    let scale = 1 / Double(total)
    let lineage = tree.lineage(node)
    guard let rootIndex = lineage.firstIndex(of: root) else { return nil }
    var start = 0.0
    var end = 1.0
    for step in (rootIndex + 1)..<lineage.count {
      let parent = lineage[step - 1]
      let target = lineage[step]
      var cursor = start
      var found = false
      for child in tree.orderedChildren(parent) {
        let span = Double(tree.size(child)) * scale
        if child == target {
          start = cursor
          end = cursor + span
          found = true
          break
        }
        cursor += span
      }
      if !found { return nil }
    }
    return (start, end, lineage.count - rootIndex - 2)
  }
}

/// Radii of sunburst rings: the focus disk in the middle, then rings that get
/// thinner outwards. Positions are continuous so zoom transitions can slide
/// rings in and out.
public struct SunburstRings: Sendable, Equatable {
  /// Ring boundaries, `edges[0]` is the hole radius, `edges.last` the outer.
  public let edges: [Double]

  public init(radius: Double, ringCount: Int = 5, holeFraction: Double = 0.34) {
    let hole = radius * holeFraction
    let weights = (0..<ringCount).map { 1.0 / (1.0 + Double($0) * 0.22) }
    let sum = weights.reduce(0, +)
    var edges = [hole]
    var r = hole
    for w in weights {
      r += (radius - hole) * w / sum
      edges.append(r)
    }
    self.edges = edges
  }

  public var hole: Double { edges[0] }
  public var outer: Double { edges[edges.count - 1] }
  public var ringCount: Int { edges.count - 1 }

  /// Radius at continuous ring position `p` (0 = hole edge, 1 = end of the
  /// first ring, …). Extends linearly beyond both ends.
  public func radius(_ p: Double) -> Double {
    if p <= 0 { return max(0, edges[0] + p * (edges[1] - edges[0])) }
    let n = ringCount
    if p >= Double(n) { return edges[n] + (p - Double(n)) * (edges[n] - edges[n - 1]) }
    let i = Int(p)
    let f = p - Double(i)
    return edges[i] + f * (edges[i + 1] - edges[i])
  }

  /// Ring index under radius `r`, nil inside the hole or outside.
  public func ring(at r: Double) -> Int? {
    guard r >= edges[0], r < outer else { return nil }
    for i in 0..<ringCount where r < edges[i + 1] { return i }
    return nil
  }

  /// Angle fraction (0 at twelve o'clock, clockwise) of a point relative to
  /// the center, in a y-down coordinate space.
  public static func fraction(dx: Double, dy: Double) -> Double {
    var a = atan2(dx, -dy) / (2 * .pi)
    if a < 0 { a += 1 }
    return a
  }
}
