import Foundation

/// Index of a node inside a `FileTree`.
public typealias NodeID = Int32

/// Compact, structure-of-arrays file tree produced by `Scanner`.
///
/// A directory's children are always stored contiguously
/// (`firstChild ..< firstChild + childCount`), and every child has a larger
/// index than its parent. Both invariants come from the scanner committing a
/// whole directory listing at once, and they keep the tree at ~35 bytes per
/// node plus names, so millions of files fit comfortably in memory.
///
/// The tree is read from many threads but mutated only on the main actor
/// (`remove`), and mutations only ever shrink sizes, so readers observe at
/// worst a slightly stale value.
public final class FileTree: @unchecked Sendable {
  public struct Flags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let directory = Flags(rawValue: 1 << 0)
    public static let package = Flags(rawValue: 1 << 1)
    public static let symlink = Flags(rawValue: 1 << 2)
    public static let hidden = Flags(rawValue: 1 << 3)
    public static let denied = Flags(rawValue: 1 << 4)
    public static let removed = Flags(rawValue: 1 << 5)
  }

  public static let root: NodeID = 0

  public let rootPath: String
  public let scannedAt: Date

  var parents: ContiguousArray<Int32>
  var firstChildren: ContiguousArray<Int32>
  var childCounts: ContiguousArray<Int32>
  var sizes: ContiguousArray<UInt64>
  var fileCounts: ContiguousArray<UInt32>
  var modified: ContiguousArray<UInt32>
  var nameOffsets: ContiguousArray<UInt32>
  var nameLengths: ContiguousArray<UInt16>
  var flags: ContiguousArray<UInt8>
  var names: ContiguousArray<UInt8>

  init(rootPath: String, storage: TreeStorage) {
    self.rootPath = rootPath
    self.scannedAt = Date()
    parents = storage.parents
    firstChildren = storage.firstChildren
    childCounts = storage.childCounts
    sizes = storage.sizes
    fileCounts = storage.fileCounts
    modified = storage.modified
    nameOffsets = storage.nameOffsets
    nameLengths = storage.nameLengths
    flags = storage.flags
    names = storage.names
  }

  public var count: Int { parents.count }

  // MARK: - Node accessors

  @inline(__always) public func size(_ id: NodeID) -> UInt64 { sizes[Int(id)] }

  @inline(__always) public func fileCount(_ id: NodeID) -> Int {
    Int(fileCounts[Int(id)])
  }

  @inline(__always) public func parent(_ id: NodeID) -> NodeID? {
    let p = parents[Int(id)]
    return p < 0 ? nil : p
  }

  @inline(__always) public func flags(_ id: NodeID) -> Flags {
    Flags(rawValue: flags[Int(id)])
  }

  @inline(__always) public func isDirectory(_ id: NodeID) -> Bool {
    flags[Int(id)] & Flags.directory.rawValue != 0
  }

  @inline(__always) public func isRemoved(_ id: NodeID) -> Bool {
    flags[Int(id)] & Flags.removed.rawValue != 0
  }

  public func modificationDate(_ id: NodeID) -> Date {
    Date(timeIntervalSince1970: TimeInterval(modified[Int(id)]))
  }

  /// Seconds since 1970, cheap for bulk filtering.
  @inline(__always) public func modificationTime(_ id: NodeID) -> UInt32 {
    modified[Int(id)]
  }

  public func name(_ id: NodeID) -> String {
    if id == FileTree.root { return (rootPath as NSString).lastPathComponent }
    let offset = Int(nameOffsets[Int(id)])
    let length = Int(nameLengths[Int(id)])
    return names.withUnsafeBufferPointer {
      String(decoding: UnsafeBufferPointer(rebasing: $0[offset..<offset + length]), as: UTF8.self)
    }
  }

  /// File extension in lower case, empty for directories without one.
  public func pathExtension(_ id: NodeID) -> String {
    let n = name(id)
    guard let dot = n.lastIndex(of: "."), dot != n.startIndex else { return "" }
    return n[n.index(after: dot)...].lowercased()
  }

  public func path(_ id: NodeID) -> String {
    var components: [String] = []
    var cur: NodeID? = id
    while let c = cur, c != FileTree.root {
      components.append(name(c))
      cur = parent(c)
    }
    var path = rootPath
    for component in components.reversed() {
      if !path.hasSuffix("/") { path += "/" }
      path += component
    }
    return path
  }

  public func url(_ id: NodeID) -> URL {
    URL(fileURLWithPath: path(id), isDirectory: isDirectory(id))
  }

  public func children(_ id: NodeID) -> Range<NodeID> {
    let first = firstChildren[Int(id)]
    guard first >= 0 else { return 0..<0 }
    return first..<(first + childCounts[Int(id)])
  }

  /// Live (not removed) children sorted by size, largest first.
  public func sortedChildren(_ id: NodeID) -> [NodeID] {
    var result = children(id).filter { !isRemoved($0) }
    result.sort { sizes[Int($0)] > sizes[Int($1)] }
    return result
  }

  /// Ancestors from the root down to `id` itself.
  public func lineage(_ id: NodeID) -> [NodeID] {
    var chain: [NodeID] = []
    var cur: NodeID? = id
    while let c = cur {
      chain.append(c)
      cur = parent(c)
    }
    return chain.reversed()
  }

  public func depth(_ id: NodeID) -> Int {
    var d = 0
    var cur = parents[Int(id)]
    while cur >= 0 {
      d += 1
      cur = parents[Int(cur)]
    }
    return d
  }

  /// Finds a node by absolute path, or nil if it is outside the tree.
  public func find(path: String) -> NodeID? {
    let standardized = (path as NSString).standardizingPath
    let root = rootPath == "/" ? "" : rootPath
    if standardized == rootPath { return FileTree.root }
    guard standardized.hasPrefix(root + "/") else { return nil }
    let rest = standardized.dropFirst(root.count + 1)
    var cur = FileTree.root
    for component in rest.split(separator: "/") {
      let target = Array(component.utf8)
      guard let next = children(cur).first(where: { nameEquals($0, target) }) else { return nil }
      cur = next
    }
    return isRemoved(cur) ? nil : cur
  }

  private func nameEquals(_ id: NodeID, _ bytes: [UInt8]) -> Bool {
    let length = Int(nameLengths[Int(id)])
    guard length == bytes.count else { return false }
    let offset = Int(nameOffsets[Int(id)])
    return names.withUnsafeBufferPointer { buf in
      bytes.withUnsafeBufferPointer { memcmp(buf.baseAddress! + offset, $0.baseAddress!, length) == 0 }
    }
  }

  // MARK: - Queries

  /// Live regular files whose size is at least `minSize`.
  public func files(atLeast minSize: UInt64) -> [NodeID] {
    var result: [NodeID] = []
    let dirOrRemoved = Flags.directory.rawValue | Flags.removed.rawValue
    sizes.withUnsafeBufferPointer { sizes in
      flags.withUnsafeBufferPointer { flags in
        for i in 1..<sizes.count where sizes[i] >= minSize && flags[i] & dirOrRemoved == 0 {
          result.append(NodeID(i))
        }
      }
    }
    return result
  }

  /// Nodes for which `predicate` holds, scanning the whole tree.
  public func nodes(where predicate: (NodeID) -> Bool) -> [NodeID] {
    (0..<NodeID(count)).filter { !isRemoved($0) && predicate($0) }
  }

  /// Live direct children named `name`.
  public func child(_ id: NodeID, named name: String) -> NodeID? {
    let target = Array(name.utf8)
    return children(id).first { !isRemoved($0) && nameEquals($0, target) }
  }

  // MARK: - Mutation

  /// Marks a node removed and subtracts its size from every ancestor.
  @MainActor public func remove(_ id: NodeID) {
    guard !isRemoved(id) else { return }
    let size = sizes[Int(id)]
    let files = fileCounts[Int(id)]
    flags[Int(id)] |= Flags.removed.rawValue
    var cur = parents[Int(id)]
    while cur >= 0 {
      sizes[Int(cur)] &-= min(size, sizes[Int(cur)])
      fileCounts[Int(cur)] &-= min(files, fileCounts[Int(cur)])
      cur = parents[Int(cur)]
    }
  }

  /// Approximate resident memory used by the tree.
  public var memoryFootprint: Int {
    count * (4 + 4 + 4 + 8 + 4 + 4 + 4 + 2 + 1) + names.count
  }
}

/// Mutable storage the scanner fills before freezing it into a `FileTree`.
struct TreeStorage {
  var parents = ContiguousArray<Int32>()
  var firstChildren = ContiguousArray<Int32>()
  var childCounts = ContiguousArray<Int32>()
  var sizes = ContiguousArray<UInt64>()
  var fileCounts = ContiguousArray<UInt32>()
  var modified = ContiguousArray<UInt32>()
  var nameOffsets = ContiguousArray<UInt32>()
  var nameLengths = ContiguousArray<UInt16>()
  var flags = ContiguousArray<UInt8>()
  var names = ContiguousArray<UInt8>()

  init(reserving capacity: Int) {
    parents.reserveCapacity(capacity)
    firstChildren.reserveCapacity(capacity)
    childCounts.reserveCapacity(capacity)
    sizes.reserveCapacity(capacity)
    fileCounts.reserveCapacity(capacity)
    modified.reserveCapacity(capacity)
    nameOffsets.reserveCapacity(capacity)
    nameLengths.reserveCapacity(capacity)
    flags.reserveCapacity(capacity)
    names.reserveCapacity(capacity * 16)
  }

  var count: Int { parents.count }

  mutating func appendRoot(modified time: UInt32) {
    parents.append(-1)
    firstChildren.append(-1)
    childCounts.append(0)
    sizes.append(0)
    fileCounts.append(0)
    modified.append(time)
    nameOffsets.append(0)
    nameLengths.append(0)
    flags.append(FileTree.Flags.directory.rawValue)
  }

  /// Appends a directory listing; returns the index of its first entry.
  mutating func commit(_ batch: DirectoryBatch, parent: Int32) -> Int32 {
    let base = Int32(parents.count)
    let nameBase = UInt32(names.count)
    names.append(contentsOf: batch.names)
    for e in batch.entries {
      parents.append(parent)
      firstChildren.append(-1)
      childCounts.append(0)
      sizes.append(e.size)
      fileCounts.append(e.isDirectory ? 0 : 1)
      modified.append(e.modified)
      nameOffsets.append(nameBase + e.nameOffset)
      nameLengths.append(e.nameLength)
      flags.append(e.flags)
    }
    firstChildren[Int(parent)] = batch.entries.isEmpty ? -1 : base
    childCounts[Int(parent)] = Int32(batch.entries.count)
    return base
  }

  /// Rolls file sizes and counts up into directories. Relies on every child
  /// having a larger index than its parent.
  mutating func aggregate() {
    sizes.withUnsafeMutableBufferPointer { sizes in
      fileCounts.withUnsafeMutableBufferPointer { counts in
        parents.withUnsafeBufferPointer { parents in
          var i = sizes.count - 1
          while i > 0 {
            let p = Int(parents[i])
            sizes[p] &+= sizes[i]
            counts[p] &+= counts[i]
            i -= 1
          }
        }
      }
    }
  }
}

/// One directory's entries, gathered by a worker before committing.
struct DirectoryBatch {
  struct Entry {
    var size: UInt64
    var modified: UInt32
    var nameOffset: UInt32
    var nameLength: UInt16
    var flags: UInt8
    var isDirectory: Bool { flags & FileTree.Flags.directory.rawValue != 0 }
  }

  var entries: [Entry] = []
  var names: [UInt8] = []

  mutating func reset() {
    entries.removeAll(keepingCapacity: true)
    names.removeAll(keepingCapacity: true)
  }
}
