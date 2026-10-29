import Foundation

/// Binary snapshot of a `FileTree`, so the app opens with the last results
/// instantly and rescans quietly in the background.
///
/// Layout: magic, version, root path, scan date, then each column as raw
/// little-endian bytes. Arrays are dumped and loaded with single copies,
/// which makes a 2-million-node tree a ~100 MB file read in well under a
/// second.
extension FileTree {
  private static let magic: UInt32 = 0x5254_4353  // "SCTR"
  private static let version: UInt32 = 1

  public func write(to url: URL) throws {
    var header = Data()
    func put<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
    }
    let rootBytes = Array(rootPath.utf8)
    put(FileTree.magic)
    put(FileTree.version)
    put(UInt32(rootBytes.count))
    header.append(contentsOf: rootBytes)
    put(Int64(scannedAt.timeIntervalSince1970))
    put(UInt64(count))
    put(UInt64(names.count))

    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temp = url.appendingPathExtension("tmp")
    FileManager.default.createFile(atPath: temp.path, contents: nil)
    let handle = try FileHandle(forWritingTo: temp)
    defer { try? handle.close() }
    try handle.write(contentsOf: header)
    func dump<T>(_ array: ContiguousArray<T>) throws {
      try array.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
    }
    try dump(parents)
    try dump(firstChildren)
    try dump(childCounts)
    try dump(sizes)
    try dump(fileCounts)
    try dump(modified)
    try dump(nameOffsets)
    try dump(nameLengths)
    try dump(flags)
    try dump(names)
    try handle.close()
    _ = try? FileManager.default.replaceItemAt(url, withItemAt: temp)
    if FileManager.default.fileExists(atPath: temp.path) {
      try FileManager.default.moveItem(at: temp, to: url)
    }
  }

  /// Loads a snapshot; nil if missing, corrupt or from another format.
  public static func read(from url: URL) -> FileTree? {
    guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
    return data.withUnsafeBytes { raw -> FileTree? in
      var offset = 0
      func get<T: FixedWidthInteger>(_: T.Type) -> T? {
        guard offset + MemoryLayout<T>.size <= raw.count else { return nil }
        defer { offset += MemoryLayout<T>.size }
        return T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self))
      }
      guard get(UInt32.self) == magic, get(UInt32.self) == version,
        let rootLength = get(UInt32.self).map(Int.init), offset + rootLength <= raw.count
      else { return nil }
      let rootPath = String(decoding: raw[offset..<offset + rootLength], as: UTF8.self)
      offset += rootLength
      guard let date = get(Int64.self), let count = get(UInt64.self).map(Int.init),
        let nameCount = get(UInt64.self).map(Int.init), count > 0
      else { return nil }

      func column<T>(_: T.Type, _ n: Int) -> ContiguousArray<T>? {
        let bytes = n * MemoryLayout<T>.stride
        guard offset + bytes <= raw.count else { return nil }
        let result = ContiguousArray<T>(unsafeUninitializedCapacity: n) { buffer, initialized in
          UnsafeMutableRawBufferPointer(buffer).copyMemory(
            from: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + bytes]))
          initialized = n
        }
        offset += bytes
        return result
      }
      var storage = TreeStorage(reserving: 0)
      guard let parents = column(Int32.self, count),
        let firstChildren = column(Int32.self, count),
        let childCounts = column(Int32.self, count),
        let sizes = column(UInt64.self, count),
        let fileCounts = column(UInt32.self, count),
        let modified = column(UInt32.self, count),
        let nameOffsets = column(UInt32.self, count),
        let nameLengths = column(UInt16.self, count),
        let flags = column(UInt8.self, count),
        let names = column(UInt8.self, nameCount),
        offset == raw.count
      else { return nil }
      storage.parents = parents
      storage.firstChildren = firstChildren
      storage.childCounts = childCounts
      storage.sizes = sizes
      storage.fileCounts = fileCounts
      storage.modified = modified
      storage.nameOffsets = nameOffsets
      storage.nameLengths = nameLengths
      storage.flags = flags
      storage.names = names
      return FileTree(
        rootPath: rootPath, storage: storage,
        scannedAt: Date(timeIntervalSince1970: TimeInterval(date)))
    }
  }

  /// Default snapshot location in the app's caches folder.
  public static var defaultCacheURL: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("com.kewldan.sector", isDirectory: true)
      .appendingPathComponent("tree.bin")
  }
}
