import Darwin
import Foundation

/// What Smart Clean needs to know about a file or folder.
struct FileFacts: Sendable {
  var path: String
  var name: String
  var size: UInt64
  var fileCount: Int
  var modified: Date
  var isDirectory: Bool

  var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
  var cleanupFile: CleanupFile { CleanupFile(url: url, size: size, fileCount: fileCount) }
}

/// Answers size and listing questions from the scanned tree when the path is
/// inside it (instant), and from the file system otherwise.
struct CleanupFileSource: @unchecked Sendable {
  let tree: FileTree?

  init(tree: FileTree?) {
    self.tree = tree
  }

  /// The tree node for `path` when the tree covers it.
  func node(_ path: String) -> NodeID? {
    guard let tree, covers(path) else { return nil }
    return tree.find(path: path)
  }

  func covers(_ path: String) -> Bool {
    guard let tree else { return false }
    return tree.rootPath == "/" || path == tree.rootPath || path.hasPrefix(tree.rootPath + "/")
  }

  func facts(_ path: String) -> FileFacts? {
    if let tree, let id = node(path) { return facts(tree, id, path: path) }
    return FileStats.facts(path)
  }

  func exists(_ path: String) -> Bool {
    if node(path) != nil { return true }
    var st = stat()
    return lstat(path, &st) == 0
  }

  /// Direct children, skipping entries removed since the scan.
  func children(_ path: String) -> [FileFacts] {
    if let tree, let id = node(path) {
      return tree.children(id).compactMap { child in
        guard !tree.isRemoved(child) else { return nil }
        let name = tree.name(child)
        return facts(tree, child, path: path + "/" + name)
      }
    }
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
    return names.compactMap { FileStats.facts(path + "/" + $0) }
  }

  private func facts(_ tree: FileTree, _ id: NodeID, path: String) -> FileFacts {
    FileFacts(
      path: path, name: (path as NSString).lastPathComponent, size: tree.size(id),
      fileCount: tree.isDirectory(id) ? tree.fileCount(id) : 1,
      modified: tree.modificationDate(id), isDirectory: tree.isDirectory(id))
  }
}

/// File-system measurements for paths outside the scanned tree.
enum FileStats {
  /// Size and file count of `path`, without following symlinks.
  static func facts(_ path: String) -> FileFacts? {
    var st = stat()
    guard lstat(path, &st) == 0 else { return nil }
    let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
    let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    let name = (path as NSString).lastPathComponent
    guard isDirectory else {
      return FileFacts(
        path: path, name: name, size: UInt64(max(0, st.st_blocks)) * 512, fileCount: 1,
        modified: modified, isDirectory: false)
    }
    let (size, files) = measure(path)
    return FileFacts(
      path: path, name: name, size: size, fileCount: files, modified: modified, isDirectory: true)
  }

  /// Allocated bytes and regular files under a directory. Physical walk:
  /// symlinks are counted as themselves and never followed, mount points
  /// are not crossed.
  static func measure(_ path: String) -> (size: UInt64, files: Int) {
    var size: UInt64 = 0
    var files = 0
    FTSWalk.walk(path) { entry in
      switch entry.info {
      case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
        if let st = entry.stat {
          size &+= UInt64(max(0, st.st_blocks)) * 512
          if entry.info == FTS_F { files += 1 }
        }
      case FTS_D:
        if let st = entry.stat { size &+= UInt64(max(0, st.st_blocks)) * 512 }
      default: break
      }
      return true
    }
    return (size, files)
  }
}

/// Thin wrapper over fts(3) in physical, single-device mode.
enum FTSWalk {
  struct Entry {
    var info: Int32
    var path: String
    var stat: stat?
    /// Errno for FTS_ERR / FTS_DNR entries.
    var error: Int32
    var ftsent: UnsafeMutablePointer<FTSENT>
  }

  /// Walks `root`, calling `visit` for every entry (directories twice:
  /// pre-order FTS_D and post-order FTS_DP). Return false to stop.
  static func walk(_ root: String, _ visit: (Entry) -> Bool) {
    guard let cPath = strdup(root) else { return }
    defer { free(cPath) }
    var paths: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
    guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
    defer { fts_close(fts) }
    while let ent = fts_read(fts) {
      let info = Int32(ent.pointee.fts_info)
      let entry = Entry(
        info: info, path: String(cString: ent.pointee.fts_path),
        stat: ent.pointee.fts_statp.map { $0.pointee }, error: ent.pointee.fts_errno, ftsent: ent)
      if !visit(entry) { break }
    }
  }
}

extension FileTree {
  /// Whether a node's name equals `bytes`, without allocating a String.
  func nameMatches(_ id: NodeID, _ bytes: [UInt8]) -> Bool {
    let length = Int(nameLengths[Int(id)])
    guard length == bytes.count else { return false }
    let offset = Int(nameOffsets[Int(id)])
    return names.withUnsafeBufferPointer { buf in
      bytes.withUnsafeBufferPointer { memcmp(buf.baseAddress! + offset, $0.baseAddress!, length) == 0 }
    }
  }

  /// Whether a node's name starts with a dot (hidden folders like `.git`).
  func nameIsDotted(_ id: NodeID) -> Bool {
    guard nameLengths[Int(id)] > 0 else { return false }
    return names[Int(nameOffsets[Int(id)])] == UInt8(ascii: ".")
  }
}
