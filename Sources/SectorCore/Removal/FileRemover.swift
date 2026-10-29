import Foundation

/// How deleted files leave the disk.
public enum RemovalMode: String, Sendable, Codable {
  /// Moved to the Trash; restorable from History until the Trash is emptied.
  case trash
  /// Deleted immediately; space frees at once and nothing can be restored.
  case permanent
}

/// One file or folder to remove, with the size the UI promised to free.
public struct RemovalItem: Sendable, Hashable, Codable {
  public var url: URL
  public var size: UInt64

  public init(url: URL, size: UInt64) {
    self.url = url
    self.size = size
  }
}

public struct RemovalOutcome: Sendable {
  public struct Removed: Sendable, Codable, Hashable {
    public var originalPath: String
    /// Where the item landed in the Trash; nil after permanent deletion.
    public var trashedPath: String?
    public var size: UInt64
  }

  public var removed: [Removed] = []
  public var failed: [(url: URL, error: String)] = []

  public var freedBytes: UInt64 { removed.reduce(0) { $0 + $1.size } }
}

/// Moves files to the Trash or deletes them, reporting progress per item.
public enum FileRemover {
  /// Removes `items` off the main thread. `progress` gets the running count
  /// of processed items and freed bytes.
  public static func remove(
    _ items: [RemovalItem], mode: RemovalMode,
    progress: (@Sendable (_ done: Int, _ freed: UInt64) -> Void)? = nil
  ) async -> RemovalOutcome {
    await Task.detached(priority: .userInitiated) {
      var outcome = RemovalOutcome()
      let fm = FileManager()
      var freed: UInt64 = 0
      for (i, item) in items.enumerated() {
        do {
          switch mode {
          case .trash:
            var resulting: NSURL?
            try fm.trashItem(at: item.url, resultingItemURL: &resulting)
            outcome.removed.append(
              .init(
                originalPath: item.url.path, trashedPath: (resulting as URL?)?.path,
                size: item.size))
          case .permanent:
            try fm.removeItem(at: item.url)
            outcome.removed.append(.init(originalPath: item.url.path, trashedPath: nil, size: item.size))
          }
          freed += item.size
        } catch {
          outcome.failed.append((item.url, error.localizedDescription))
        }
        progress?(i + 1, freed)
      }
      return outcome
    }.value
  }

  /// Moves a trashed item back to where it came from. Fails if the original
  /// location is occupied or the Trash was emptied.
  public static func restore(_ removed: RemovalOutcome.Removed) throws {
    guard let trashed = removed.trashedPath else {
      throw CocoaError(.fileNoSuchFile)
    }
    let fm = FileManager.default
    let destination = URL(fileURLWithPath: removed.originalPath)
    try fm.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: URL(fileURLWithPath: trashed), to: destination)
  }

  /// Whether the trashed copy is still there to restore.
  public static func canRestore(_ removed: RemovalOutcome.Removed) -> Bool {
    guard let trashed = removed.trashedPath else { return false }
    return FileManager.default.fileExists(atPath: trashed)
  }
}
