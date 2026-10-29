import Foundation

/// Picks the folders worth naming on the overview: rather than "/Users" or
/// "~", it descends through containers and through folders one child
/// dominates, and skips system internals the user cannot act on.
public enum LargestFolders {
  /// Folders, largest first.
  ///
  /// - Parameters:
  ///   - alwaysExpand: containers that are never shown themselves (the root,
  ///     `/Users`, the home folder, `~/Library`).
  ///   - skip: subtrees never shown or entered.
  ///   - dominance: a folder whose largest child folder holds at least this
  ///     share of it is replaced by that child's level.
  public static func select(
    tree: FileTree, limit: Int = 5, alwaysExpand: Set<NodeID>, skip: Set<NodeID>,
    dominance: Double = 0.6, maxSteps: Int = 256
  ) -> [NodeID] {
    guard limit > 0, tree.size(FileTree.root) > 0 else { return [] }
    var frontier: [NodeID] = [FileTree.root]

    func isCandidate(_ id: NodeID) -> Bool {
      tree.isDirectory(id) && !skip.contains(id) && !tree.isRemoved(id) && tree.size(id) > 0
    }

    func shouldExpand(_ id: NodeID) -> Bool {
      if alwaysExpand.contains(id) { return true }
      let flags = tree.flags(id)
      guard flags.contains(.directory), !flags.contains(.package) else { return false }
      guard let largest = tree.largestChildren(id, limit: 1).first,
        tree.isDirectory(largest), !skip.contains(largest)
      else { return false }
      return Double(tree.size(largest)) >= dominance * Double(tree.size(id))
    }

    var visible: [NodeID] = []
    for _ in 0..<maxSteps {
      frontier.sort { tree.size($0) != tree.size($1) ? tree.size($0) > tree.size($1) : $0 < $1 }
      // Containers stay in the frontier until expanded, so look a little
      // past `limit` to find the next one to open.
      visible = Array(frontier.lazy.filter(isCandidate).prefix(limit))
      let pending = frontier.lazy.filter { isCandidate($0) || alwaysExpand.contains($0) }
        .prefix(limit + alwaysExpand.count)
      guard let target = pending.first(where: shouldExpand) else { break }
      frontier.removeAll { $0 == target }
      frontier.append(contentsOf: tree.children(target).filter { !tree.isRemoved($0) })
    }
    return visible.filter { !alwaysExpand.contains($0) }
  }

  /// `select` with the standard containers and system folders of a macOS
  /// startup disk or home-folder scan.
  public static func select(tree: FileTree, home: String, limit: Int = 5) -> [NodeID] {
    var expand: Set<NodeID> = [FileTree.root]
    for path in ["/Users", home, home + "/Library"] {
      if let id = tree.find(path: path) { expand.insert(id) }
    }
    var skip = Set<NodeID>()
    let systemPaths = [
      "/System", "/private", "/usr", "/bin", "/sbin", "/cores", "/dev", "/Volumes", "/etc",
      "/var", "/tmp", "/.Spotlight-V100", "/.fseventsd", "/.DocumentRevisions-V100", "/.vol",
      "/.PKInstallSandboxManager-SystemSoftware", home + "/.Trash",
    ]
    for path in systemPaths {
      if let id = tree.find(path: path) { skip.insert(id) }
    }
    return select(tree: tree, limit: limit, alwaysExpand: expand, skip: skip)
  }
}
