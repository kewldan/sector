import Foundation

/// Off-main sizes of single folders (Trash, Downloads) for the menu bar,
/// independent of the last full scan.
enum FolderSize {
  static var trashURL: URL {
    FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
  }

  static var downloadsURL: URL {
    FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
  }

  /// Allocated bytes of everything under `url`, or nil when it can't be read.
  static func allocated(_ url: URL) async -> UInt64? {
    await Task.detached(priority: .utility) { measure(url) }.value
  }

  /// Top-level items of the Trash with their sizes, largest first; nil when
  /// the Trash can't be read (no Full Disk Access).
  static func trashContents() async -> [DeletionItem]? {
    let trash = trashURL
    return await Task.detached(priority: .utility) { () -> [DeletionItem]? in
      let fm = FileManager.default
      guard
        let children = try? fm.contentsOfDirectory(
          at: trash, includingPropertiesForKeys: [.isDirectoryKey], options: [])
      else { return nil }
      return
        children
        .filter { $0.lastPathComponent != ".DS_Store" }
        .map { DeletionItem(url: $0, size: measure($0) ?? 0) }
        .sorted { $0.size > $1.size }
    }.value
  }

  private static func measure(_ url: URL) -> UInt64? {
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]
    guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
    guard values.isDirectory == true else {
      return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
    guard
      let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: Array(keys), options: [],
        errorHandler: { _, _ in true })
    else { return nil }
    var total: UInt64 = 0
    while let item = enumerator.nextObject() as? URL {
      guard let v = try? item.resourceValues(forKeys: keys), v.isRegularFile == true else {
        continue
      }
      total += UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
    }
    return total
  }
}
