import Foundation
import Observation
import SectorCore
import SwiftUI

/// The item under the pointer in the disk map.
struct ExplorerHover: Equatable, Sendable {
  /// Index of the segment or tile in the layout being drawn.
  var index: Int
  /// The node, or for "Прочее" the folder whose small items it merges.
  var node: NodeID
  var isOther: Bool
  var size: UInt64
  var otherCount: Int
}

/// One breadcrumb.
struct ExplorerCrumb: Identifiable, Equatable, Sendable {
  /// nil for path components above the scan root (not navigable).
  var node: NodeID?
  var name: String
  var id: String
}

/// A zoom between a folder (`outer`) and one of its descendants (`inner`).
/// Both layouts are kept while the transition runs; the charts interpolate
/// between them with `ExplorerModel.zoomProgress`.
struct ExplorerZoom: Sendable {
  var outer: NodeID
  var inner: NodeID
  var outerRings: SunburstLayout
  var innerRings: SunburstLayout
  var outerTiles: TreemapSource
  var innerTiles: TreemapSource
  /// Arc of `inner` inside the outer sunburst and its ring index there.
  var spanStart: Double
  var spanEnd: Double
  var depth: Int
  /// Nodes from `inner` up to (not including) `outer`, innermost first;
  /// the treemap zooms from the deepest one it drew.
  var innerLineage: [NodeID]
  var zoomingIn: Bool

  /// 0 shows the outer folder, 1 the inner one.
  func position(_ progress: Double) -> Double {
    let p = min(1, max(0, progress))
    return zoomingIn ? p : 1 - p
  }
}

/// State of the disk map: focus folder, precomputed layouts, zoom
/// transition, hover and selection. Lives across visits to the screen so
/// coming back keeps the place; Overview hands folders over with `open`.
@Observable @MainActor
final class ExplorerModel {
  enum Mode: String {
    case rings, tiles
  }

  static let shared = ExplorerModel()

  var mode: Mode = .rings
  private(set) var focus: NodeID = FileTree.root
  private(set) var rings: SunburstLayout?
  private(set) var tiles: TreemapSource?
  private(set) var crumbs: [ExplorerCrumb] = []
  private(set) var zoom: ExplorerZoom?
  /// Animated 0 → 1 while `zoom` runs.
  var zoomProgress: Double = 0
  /// Bumped when the chart should replay its entrance animation.
  private(set) var entrance = 0
  var hover: ExplorerHover?
  var selection: NodeID?
  private(set) var forward: [NodeID] = []

  @ObservationIgnored private weak var tree: FileTree?
  @ObservationIgnored private var version = -1
  @ObservationIgnored private var queued: NodeID?
  @ObservationIgnored private var loading = false
  @ObservationIgnored private var pendingPath: String?
  @ObservationIgnored private var cache: [NodeID: Entry] = [:]
  @ObservationIgnored private var cacheOrder: [NodeID] = []
  @ObservationIgnored private var rootName = ""

  private struct Entry: Sendable {
    var rings: SunburstLayout
    var tiles: TreemapSource
    var crumbs: [ExplorerCrumb]
  }

  var canGoUp: Bool { focus != FileTree.root }
  var canGoForward: Bool { !forward.isEmpty }
  var isZooming: Bool { zoom != nil }

  /// Opens `path` (a folder, or a file whose folder is shown with the file
  /// selected) the next time the map appears.
  func open(path: String?) {
    pendingPath = path ?? ""
  }

  // MARK: - Syncing with the scan

  /// Brings the map up to date with `app.tree`: resets on a new scan,
  /// relayouts after removals and applies a pending `open`.
  func sync(with app: AppModel) async {
    guard let tree = app.tree else {
      reset()
      return
    }
    rootName = tree.rootPath == "/" ? (app.volume?.name ?? "Macintosh HD") : ""
    var target = focus
    var replay = false
    if tree !== self.tree {
      self.tree = tree
      version = app.treeVersion
      clearCache()
      forward = []
      selection = nil
      hover = nil
      zoom = nil
      zoomProgress = 0
      target = FileTree.root
      replay = true
    } else if version != app.treeVersion {
      version = app.treeVersion
      clearCache()
      hover = nil
      if let s = selection, tree.isRemoved(s) { selection = nil }
      forward.removeAll { tree.isRemoved($0) }
    } else if pendingPath == nil && rings != nil {
      return
    }

    if let path = pendingPath {
      pendingPath = nil
      if path.isEmpty {
        if focus != FileTree.root { replay = true }
        target = FileTree.root
      } else if let id = tree.find(path: path) {
        let folder = tree.isDirectory(id) ? id : (tree.parent(id) ?? FileTree.root)
        if folder != focus { replay = true }
        target = folder
        selection = tree.isDirectory(id) ? nil : id
        forward = []
      }
    }
    while tree.isRemoved(target), let parent = tree.parent(target) { target = parent }

    let entry = await load(target, in: tree)
    guard self.tree === tree else { return }
    focus = target
    apply(entry)
    zoom = nil
    zoomProgress = 0
    if replay { entrance += 1 }
  }

  private func reset() {
    tree = nil
    rings = nil
    tiles = nil
    crumbs = []
    zoom = nil
    hover = nil
    selection = nil
    forward = []
    focus = FileTree.root
    clearCache()
  }

  // MARK: - Navigation

  /// Zooms the map into `target` (a folder) or out to it, animating when
  /// one is inside the other.
  func zoom(to target: NodeID) {
    guard let tree, tree.isDirectory(target), !tree.isRemoved(target) else { return }
    if zoom != nil || loading {
      queued = target
      return
    }
    guard target != focus else { return }
    let from = focus
    let fromRings = rings
    let fromTiles = tiles

    if tree.isDescendant(focus, of: target) {
      // Going up: everything between the target and the old focus becomes
      // "forward" history, nearest level last.
      var chain: [NodeID] = []
      var cur: NodeID? = focus
      while let c = cur, c != target {
        chain.append(c)
        cur = tree.parent(c)
      }
      forward.append(contentsOf: chain)
    } else if forward.last == target {
      forward.removeLast()
    } else {
      forward = []
    }

    hover = nil
    selection = nil
    focus = target
    loading = true
    Task {
      let entry = await load(target, in: tree)
      loading = false
      guard focus == target, self.tree === tree else { return }
      var transition: ExplorerZoom?
      if let fromRings, let fromTiles {
        if tree.isDescendant(target, of: from),
          let span = SunburstLayout.span(of: target, under: from, in: tree)
        {
          transition = ExplorerZoom(
            outer: from, inner: target, outerRings: fromRings, innerRings: entry.rings,
            outerTiles: fromTiles, innerTiles: entry.tiles, spanStart: span.start,
            spanEnd: span.end, depth: span.depth, innerLineage: lineage(target, below: from),
            zoomingIn: true)
        } else if tree.isDescendant(from, of: target),
          let span = SunburstLayout.span(of: from, under: target, in: tree)
        {
          transition = ExplorerZoom(
            outer: target, inner: from, outerRings: entry.rings, innerRings: fromRings,
            outerTiles: entry.tiles, innerTiles: fromTiles, spanStart: span.start,
            spanEnd: span.end, depth: span.depth, innerLineage: lineage(from, below: target),
            zoomingIn: false)
        }
      }
      apply(entry)
      guard let transition else {
        entrance += 1
        runQueued()
        return
      }
      zoom = transition
      zoomProgress = 0
      withAnimation(Motion.resolve(Motion.smooth), completionCriteria: .removed) {
        zoomProgress = 1
      } completion: {
        self.finishZoom()
      }
    }
  }

  func goUp() {
    guard let tree, let parent = tree.parent(focus) else { return }
    zoom(to: parent)
  }

  func goForward() {
    guard let next = forward.last else { return }
    zoom(to: next)
  }

  /// Clicking an item: folders zoom in, files get selected.
  func activate(node: NodeID, isOther: Bool) {
    guard let tree else { return }
    if isOther {
      if node != focus { zoom(to: node) }
    } else if tree.isDirectory(node) {
      zoom(to: node)
    } else {
      selection = selection == node ? nil : node
    }
  }

  private func finishZoom() {
    zoom = nil
    zoomProgress = 0
    runQueued()
  }

  private func runQueued() {
    if let next = queued {
      queued = nil
      zoom(to: next)
    }
  }

  private func lineage(_ node: NodeID, below ancestor: NodeID) -> [NodeID] {
    guard let tree else { return [] }
    var result: [NodeID] = []
    var cur: NodeID? = node
    while let c = cur, c != ancestor {
      result.append(c)
      cur = tree.parent(c)
    }
    return result
  }

  // MARK: - Layout cache

  private func apply(_ entry: Entry) {
    rings = entry.rings
    tiles = entry.tiles
    crumbs = entry.crumbs
  }

  private func load(_ id: NodeID, in tree: FileTree) async -> Entry {
    if let hit = cache[id] {
      cacheOrder.removeAll { $0 == id }
      cacheOrder.append(id)
      return hit
    }
    let rootName = rootName
    let entry = await Task.detached(priority: .userInitiated) {
      Entry(
        rings: SunburstLayout.make(tree: tree, root: id),
        tiles: TreemapSource.make(tree: tree, root: id),
        crumbs: ExplorerModel.makeCrumbs(id, tree: tree, rootName: rootName))
    }.value
    cache[id] = entry
    cacheOrder.append(id)
    if cacheOrder.count > 12 { cache[cacheOrder.removeFirst()] = nil }
    return entry
  }

  private func clearCache() {
    cache = [:]
    cacheOrder = []
  }

  /// Breadcrumbs from the disk down to `id`, with Finder's localized names.
  /// Runs off the main actor (it asks the file system for display names).
  nonisolated private static func makeCrumbs(
    _ id: NodeID, tree: FileTree, rootName: String
  ) -> [ExplorerCrumb] {
    let fm = FileManager.default
    var crumbs: [ExplorerCrumb] = []
    if tree.rootPath != "/" {
      // Components above a home-folder scan root, shown but not navigable.
      var path = ""
      let volume = VolumeInfo.startup()?.name ?? "Macintosh HD"
      crumbs.append(ExplorerCrumb(node: nil, name: volume, id: "/"))
      let parts = tree.rootPath.split(separator: "/").dropLast()
      for part in parts {
        path += "/" + part
        crumbs.append(ExplorerCrumb(node: nil, name: fm.displayName(atPath: path), id: path))
      }
    }
    for node in tree.lineage(id) {
      let path = tree.path(node)
      let name: String
      if node == FileTree.root && tree.rootPath == "/" {
        name = rootName.isEmpty ? "Macintosh HD" : rootName
      } else {
        name = fm.displayName(atPath: path)
      }
      crumbs.append(ExplorerCrumb(node: node, name: name, id: path))
    }
    return crumbs
  }
}
