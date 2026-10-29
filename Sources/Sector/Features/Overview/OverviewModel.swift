import Foundation
import Observation
import SectorCore

/// Everything Overview derives from the tree, computed off the main actor.
struct OverviewSnapshot: Sendable {
  struct Folder: Identifiable, Sendable, Equatable {
    var id: NodeID
    var name: String
    var path: String
    /// Parent folder for the subtitle ("~/Pictures").
    var location: String
    var size: UInt64
  }

  var folders: [Folder] = []
  /// Top-level items in `~/.Trash`.
  var trash: [DeletionItem] = []
  var trashSize: UInt64 = 0
  /// Files in `~/Downloads` untouched for `minimumAgeDays`.
  var oldDownloadsSize: UInt64 = 0
  var oldDownloadsCount = 0
  /// DerivedData and Xcode's own cache, both rebuilt on demand.
  var xcodeCachesSize: UInt64 = 0

  static func compute(
    tree: FileTree, home: String, minimumAgeDays: Int, now: Date = Date()
  ) -> OverviewSnapshot {
    var snapshot = OverviewSnapshot()

    snapshot.folders = LargestFolders.select(tree: tree, home: home, limit: 5).map { id in
      let raw = tree.name(id)
      let name =
        tree.flags(id).contains(.package) ? (raw as NSString).deletingPathExtension : raw
      let parent = tree.parent(id).map { tree.path($0) } ?? tree.rootPath
      return Folder(
        id: id, name: name, path: tree.path(id), location: ExplorerFormat.displayPath(parent),
        size: tree.size(id))
    }

    if let trash = tree.find(path: home + "/.Trash") {
      snapshot.trash = tree.orderedChildren(trash).map {
        DeletionItem(url: tree.url($0), size: tree.size($0))
      }
      snapshot.trashSize = tree.size(trash)
    }

    if let downloads = tree.find(path: home + "/Downloads") {
      let cutoff = UInt32(clamping: Int(now.timeIntervalSince1970) - minimumAgeDays * 86_400)
      var stack = [downloads]
      while let id = stack.popLast() {
        for child in tree.children(id) where !tree.isRemoved(child) {
          if tree.isDirectory(child) {
            stack.append(child)
          } else if tree.modificationTime(child) < cutoff && tree.size(child) > 0 {
            snapshot.oldDownloadsSize &+= tree.size(child)
            snapshot.oldDownloadsCount += 1
          }
        }
      }
    }

    for path in ["/Library/Developer/Xcode/DerivedData", "/Library/Caches/com.apple.dt.Xcode"] {
      if let id = tree.find(path: home + path) { snapshot.xcodeCachesSize &+= tree.size(id) }
    }
    return snapshot
  }
}

/// Caches the overview snapshot across visits; recomputes only when the
/// tree (or the age threshold) changes.
@Observable @MainActor
final class OverviewModel {
  static let shared = OverviewModel()

  private(set) var snapshot: OverviewSnapshot?

  private struct Key: Equatable {
    var version: Int
    var minimumAgeDays: Int
  }

  @ObservationIgnored private weak var tree: FileTree?
  @ObservationIgnored private var key: Key?

  func refresh(app: AppModel) async {
    guard let tree = app.tree else {
      snapshot = nil
      return
    }
    let key = Key(version: app.treeVersion, minimumAgeDays: app.settings.minimumAgeDays)
    if tree === self.tree && key == self.key && snapshot != nil { return }
    let home = NSHomeDirectory()
    let result = await Task.detached(priority: .userInitiated) {
      OverviewSnapshot.compute(tree: tree, home: home, minimumAgeDays: key.minimumAgeDays)
    }.value
    guard !Task.isCancelled, app.tree === tree, app.treeVersion == key.version else { return }
    snapshot = result
    self.tree = tree
    self.key = key
  }
}
