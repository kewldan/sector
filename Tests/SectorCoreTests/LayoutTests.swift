import CoreGraphics
import Foundation
import Testing

@testable import SectorCore

/// In-memory tree description: a file has a size, a folder has children.
private indirect enum Spec {
  case file(String, UInt64)
  case dir(String, [Spec])
  case package(String, [Spec])

  var name: String {
    switch self {
    case .file(let n, _), .dir(let n, _), .package(let n, _): return n
    }
  }
}

/// Builds a `FileTree` breadth-first, the way the scanner commits listings.
private func makeTree(root: String = "/", _ children: [Spec]) -> FileTree {
  var storage = TreeStorage(reserving: 64)
  storage.appendRoot(modified: 0)
  var queue: [(node: Int32, children: [Spec])] = [(0, children)]
  while !queue.isEmpty {
    let (node, specs) = queue.removeFirst()
    guard !specs.isEmpty else { continue }
    var batch = DirectoryBatch()
    for spec in specs {
      let bytes = Array(spec.name.utf8)
      var flags: UInt8 = 0
      var size: UInt64 = 0
      switch spec {
      case .file(_, let s): size = s
      case .dir: flags = FileTree.Flags.directory.rawValue
      case .package:
        flags = FileTree.Flags.directory.rawValue | FileTree.Flags.package.rawValue
      }
      batch.entries.append(
        .init(
          size: size, modified: 0, nameOffset: UInt32(batch.names.count),
          nameLength: UInt16(bytes.count), flags: flags))
      batch.names.append(contentsOf: bytes)
    }
    let base = storage.commit(batch, parent: node)
    for (k, spec) in specs.enumerated() {
      switch spec {
      case .dir(_, let c), .package(_, let c): queue.append((base + Int32(k), c))
      case .file: break
      }
    }
  }
  storage.aggregate()
  return FileTree(rootPath: root, storage: storage)
}

// MARK: - Ordering

@Test func orderedAndLargestChildren() {
  let tree = makeTree([.file("a", 10), .file("b", 30), .file("c", 20), .file("z", 0)])
  let ordered = tree.orderedChildren(FileTree.root).map(tree.name)
  #expect(ordered == ["b", "c", "a"])
  #expect(tree.largestChildren(FileTree.root, limit: 2).map(tree.name) == ["b", "c"])
  #expect(tree.largestChildren(FileTree.root, limit: 10).count == 3)
}

// MARK: - Sunburst

@Test func sunburstSpansNestInsideParents() throws {
  let tree = makeTree([
    .dir("big", [.file("x", 500), .dir("y", [.file("y1", 200), .file("y2", 100)])]),
    .file("mid", 150),
    .file("small", 50),
  ])
  let layout = SunburstLayout.make(tree: tree, root: FileTree.root, maxDepth: 5, minSpan: 0.001)
  #expect(layout.total == 1000)
  let ring0 = layout.segments[layout.rings[0]]
  #expect(ring0.map(\.size) == [800, 150, 50])
  #expect(abs(ring0.last!.end - 1) < 1e-9)
  for s in layout.segments where s.parent >= 0 {
    let p = layout.segments[Int(s.parent)]
    #expect(s.start >= p.start - 1e-9 && s.end <= p.end + 1e-9)
    #expect(s.depth == p.depth + 1)
  }
  // Rings are sorted by angle for hit-testing.
  for ring in layout.rings {
    let starts = layout.segments[ring].map(\.start)
    #expect(starts == starts.sorted())
  }
  let y = try #require(tree.find(path: "/big/y"))
  let i = try #require(layout.index(of: y))
  let exact = try #require(SunburstLayout.span(of: y, under: FileTree.root, in: tree))
  #expect(abs(exact.start - layout.segments[i].start) < 1e-9)
  #expect(abs(exact.end - layout.segments[i].end) < 1e-9)
  #expect(exact.depth == 1)
  #expect(layout.segment(depth: 1, at: (exact.start + exact.end) / 2) == i)
  #expect(layout.segment(depth: 0, at: 0.999) != nil)
  #expect(layout.segment(depth: 7, at: 0.5) == nil)
}

@Test func sunburstMergesSmallChildren() {
  var specs: [Spec] = [.file("huge", 10_000)]
  for i in 0..<50 { specs.append(.file("tiny\(i)", 1)) }
  let tree = makeTree([.dir("d", specs)])
  let layout = SunburstLayout.make(tree: tree, root: FileTree.root, minSpan: 0.003)
  let ring1 = Array(layout.segments[layout.rings[1]])
  #expect(ring1.count == 2)
  let other = ring1[1]
  #expect(other.isOther)
  #expect(other.otherCount == 50)
  #expect(other.size == 50)
}

@Test func sunburstRespectsDepthLimit() {
  let tree = makeTree([.dir("a", [.dir("b", [.dir("c", [.file("f", 10)])])])])
  let layout = SunburstLayout.make(tree: tree, root: FileTree.root, maxDepth: 2)
  #expect(layout.rings.count == 2)
  #expect(layout.segments.allSatisfy { $0.depth < 2 })
}

@Test func ringRadiiAreMonotonic() {
  let rings = SunburstRings(radius: 200)
  #expect(rings.edges.count == 6)
  #expect(rings.edges == rings.edges.sorted())
  #expect(abs(rings.outer - 200) < 1e-9)
  #expect(abs(rings.radius(2.5) - (rings.edges[2] + rings.edges[3]) / 2) < 1e-9)
  #expect(rings.ring(at: rings.hole - 1) == nil)
  #expect(rings.ring(at: (rings.edges[0] + rings.edges[1]) / 2) == 0)
  #expect(rings.ring(at: 199.9) == 4)
  #expect(abs(SunburstRings.fraction(dx: 1, dy: 0) - 0.25) < 1e-9)
  #expect(abs(SunburstRings.fraction(dx: 0, dy: 1) - 0.5) < 1e-9)
  #expect(abs(SunburstRings.fraction(dx: -1, dy: 0) - 0.75) < 1e-9)
}

// MARK: - Treemap

@Test func squarifyFillsRectProportionally() {
  let rect = CGRect(x: 10, y: 20, width: 600, height: 400)
  let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
  let rects = Squarify.layout(values, in: rect)
  let total = values.reduce(0, +)
  var covered = 0.0
  for (v, r) in zip(values, rects) {
    let area = Double(r.width * r.height)
    covered += area
    #expect(abs(area - v / total * 240_000) < 1)
    #expect(r.minX >= rect.minX - 0.01 && r.maxX <= rect.maxX + 0.01)
    #expect(r.minY >= rect.minY - 0.01 && r.maxY <= rect.maxY + 0.01)
  }
  #expect(abs(covered - 240_000) < 1)
  for i in rects.indices {
    for j in rects.indices where j > i {
      let overlap = rects[i].intersection(rects[j])
      #expect(overlap.isNull || overlap.width * overlap.height < 0.5)
    }
  }
  // Squarified tiles stay reasonably square.
  let ratios = rects.map { max($0.width / $0.height, $0.height / $0.width) }
  #expect(ratios.max()! < 4)
}

@Test func treemapGroupsAndMergesTail() throws {
  var small: [Spec] = []
  for i in 0..<200 { small.append(.file("s\(i)", 10)) }
  let tree = makeTree([
    .dir("docs", [.file("a", 4000), .file("b", 2000)]),
    .file("movie", 3000),
    .dir("misc", small),
  ])
  let source = TreemapSource.make(tree: tree, root: FileTree.root)
  #expect(source.entries.map(\.name) == ["docs", "movie", "misc"])
  let bounds = CGRect(x: 0, y: 0, width: 800, height: 500)
  let layout = TreemapLayout.make(source: source, bounds: bounds)
  let docsID = try #require(tree.find(path: "/docs"))
  let aID = try #require(tree.find(path: "/docs/a"))
  let miscID = try #require(tree.find(path: "/misc"))
  let docs = try #require(layout.index(of: docsID))
  #expect(layout.tiles[docs].isGroup)
  let a = try #require(layout.index(of: aID))
  #expect(layout.tiles[a].parent == Int32(docs))
  #expect(layout.tiles[docs].rect.contains(layout.tiles[a].rect))
  #expect(layout.hit(CGPoint(x: layout.tiles[a].rect.midX, y: layout.tiles[a].rect.midY)) == a)
  #expect(layout.isWithin(a, docs))
  // The 200 small files inside "misc" collapse into an "other" tile.
  let misc = try #require(layout.index(of: miscID))
  let inside = layout.tiles.indices.filter { layout.tiles[$0].parent == Int32(misc) }
  #expect(inside.count < 200)
  #expect(inside.contains { layout.tiles[$0].isOther })
  for tile in layout.tiles { #expect(bounds.contains(tile.rect)) }
}

// MARK: - Largest folders

@Test func largestFoldersDescendThroughContainers() throws {
  let tree = makeTree([
    .dir("System", [.file("kernel", 90_000)]),
    .dir(
      "Users",
      [
        .dir(
          "u",
          [
            .dir("Developer", [.file("p1", 30_000), .file("p2", 25_000)]),
            .dir("Pictures", [.package("Photos Library", [.file("img", 40_000)]), .file("x", 1)]),
            .dir(
              "Library", [.dir("Caches", [.file("c", 12_000)]), .dir("Logs", [.file("l", 500)])]),
            .dir(".Trash", [.file("t", 80_000)]),
            .file("loose.bin", 70_000),
          ]),
        .dir("Shared", [.file("s", 100)]),
      ]),
    .dir("Applications", [.file("Xcode", 20_000)]),
  ])
  let ids = LargestFolders.select(tree: tree, home: "/Users/u", limit: 4)
  let paths = ids.map(tree.path)
  #expect(
    paths == [
      "/Users/u/Developer", "/Users/u/Pictures/Photos Library", "/Applications",
      "/Users/u/Library/Caches",
    ])
}
