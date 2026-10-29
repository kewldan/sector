import CryptoKit
import Darwin
import Foundation
import Synchronization

/// One copy inside a `DuplicateGroup`.
public struct DuplicateFile: Sendable, Hashable, Identifiable {
  public var id: String { path }
  public var path: String
  /// Logical length in bytes (identical for every copy of a group).
  public var size: UInt64
  /// Blocks allocated on disk.
  public var allocatedSize: UInt64
  /// Blocks owned by this file alone, i.e. what deleting it frees. Close to
  /// zero for an APFS clone whose blocks are shared with another copy.
  public var privateSize: UInt64
  public var created: Date
  public var modified: Date

  public init(
    path: String, size: UInt64, allocatedSize: UInt64, privateSize: UInt64, created: Date,
    modified: Date
  ) {
    self.path = path
    self.size = size
    self.allocatedSize = allocatedSize
    self.privateSize = privateSize
    self.created = created
    self.modified = modified
  }

  public var url: URL { URL(fileURLWithPath: path) }
  public var name: String { (path as NSString).lastPathComponent }
  public var directory: String { (path as NSString).deletingLastPathComponent }

  /// An APFS clone: deleting it frees (almost) nothing.
  public var isClone: Bool { privateSize < max(allocatedSize / 20, 1) }
}

/// Files with byte-identical content (same size, same SHA-256).
public struct DuplicateGroup: Sendable, Hashable, Identifiable {
  /// Hex SHA-256 of the content.
  public var id: String
  public var size: UInt64
  /// Copies, oldest first.
  public var files: [DuplicateFile]

  public init(id: String, size: UInt64, files: [DuplicateFile]) {
    self.id = id
    self.size = size
    self.files = files
  }

  public var name: String { files.first?.name ?? "" }

  /// Bytes freed by deleting every copy except `kept`.
  public func waste(keeping kept: String?) -> UInt64 {
    let keep = kept ?? files.first?.path
    return files.reduce(0) { $1.path == keep ? $0 : $0 + $1.privateSize }
  }

  /// The copy worth keeping: one outside Downloads and Desktop when there
  /// is one, otherwise the oldest.
  public func autoOriginal(home: String = NSHomeDirectory()) -> String? {
    let transient = ["Downloads", "Desktop"].map { home + "/" + $0 + "/" }
    let settled = files.filter { file in !transient.contains { file.path.hasPrefix($0) } }
    let pool = settled.isEmpty ? files : settled
    return pool.min { a, b in
      if a.created != b.created { return a.created < b.created }
      if a.modified != b.modified { return a.modified < b.modified }
      return a.path.count < b.path.count
    }?.path
  }
}

/// Progress of a `DuplicateFinder` run.
public struct DuplicateProgress: Sendable, Equatable {
  public enum Phase: Int, Sendable {
    /// Picking candidate files from the tree.
    case collecting
    /// Hashing the first and last 64 KB of same-size files.
    case comparing
    /// Full SHA-256 of files whose partial hashes match.
    case hashing
    case finished
  }

  public var phase: Phase = .collecting
  public var hashedBytes: UInt64 = 0
  /// Bytes that will be read in total; grows when full hashing starts.
  public var totalBytes: UInt64 = 0
  /// Files left after grouping by size.
  public var candidates: Int = 0

  public init() {}

  public var fraction: Double {
    totalBytes == 0 ? 0 : min(1, Double(hashedBytes) / Double(totalBytes))
  }
}

/// Finds byte-identical files in a scanned `FileTree`.
///
/// Pipeline: regular files ≥ `minSize` outside system and app-internal
/// locations → group by length → SHA-256 of the first and last 64 KB →
/// full streamed SHA-256 only for groups that still collide. Reads run on
/// a few dedicated threads (disks prefer bounded parallelism), bypass the
/// page cache and stop promptly on `cancel()`.
public final class DuplicateFinder: @unchecked Sendable {
  public struct Options: Sendable {
    public var minSize: UInt64
    /// Folders never searched (absolute paths, e.g. the user's exclusions).
    public var excludedPaths: [String]
    public var homePath: String
    public var maxConcurrency: Int

    public init(
      minSize: UInt64 = 1_000_000, excludedPaths: [String] = [],
      homePath: String = NSHomeDirectory(), maxConcurrency: Int = 4
    ) {
      self.minSize = minSize
      self.excludedPaths = excludedPaths
      self.homePath = homePath
      self.maxConcurrency = max(1, maxConcurrency)
    }
  }

  static let partialChunk = 64 * 1024
  static let fullChunk = 1 << 20

  /// System locations that hold no user documents.
  static let systemPaths = [
    "/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/opt", "/cores", "/dev",
    "/Applications", "/Volumes", "/nix",
  ]
  /// Folder names skipped anywhere: dependency caches whose files must stay.
  static let skippedNames: Set<String> = ["node_modules", "Pods", "DerivedData"]

  public let tree: FileTree
  public let options: Options

  private let phase = Atomic<Int>(DuplicateProgress.Phase.collecting.rawValue)
  private let hashedBytes = Atomic<UInt64>(0)
  private let totalBytes = Atomic<UInt64>(0)
  private let candidateCount = Atomic<Int>(0)
  private let cancelled = Atomic<Bool>(false)

  public init(tree: FileTree, options: Options = Options()) {
    self.tree = tree
    self.options = options
  }

  public var progress: DuplicateProgress {
    var p = DuplicateProgress()
    p.phase = DuplicateProgress.Phase(rawValue: phase.load(ordering: .relaxed)) ?? .collecting
    p.hashedBytes = hashedBytes.load(ordering: .relaxed)
    p.totalBytes = totalBytes.load(ordering: .relaxed)
    p.candidates = candidateCount.load(ordering: .relaxed)
    return p
  }

  public func cancel() { cancelled.store(true, ordering: .relaxed) }

  public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

  /// Runs on a dedicated thread; nil if cancelled.
  public func find() async -> [DuplicateGroup]? {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let thread = Thread { continuation.resume(returning: self.run()) }
        thread.qualityOfService = .userInitiated
        thread.start()
      }
    } onCancel: {
      cancel()
    }
  }

  /// Blocking variant of `find()`. Groups come sorted by reclaimable bytes,
  /// largest first.
  public func run() -> [DuplicateGroup]? {
    // 1. Candidates grouped by logical length.
    let candidates = collect()
    var bySize: [UInt64: [Candidate]] = [:]
    for c in candidates { bySize[c.size, default: []].append(c) }
    let sizeGroups = bySize.values.compactMap { group -> [Candidate]? in
      // Hard links share an inode: one file, not duplicates.
      var seen = Set<FileKey>()
      let unique = group.filter { seen.insert($0.key).inserted }
      return unique.count > 1 ? unique : nil
    }
    guard !isCancelled else { return nil }

    // 2. Partial hashes.
    let partialFiles = sizeGroups.flatMap { $0 }
    candidateCount.store(partialFiles.count, ordering: .relaxed)
    let partialBytes = partialFiles.reduce(UInt64(0)) {
      $0 + min($1.size, UInt64(2 * Self.partialChunk))
    }
    totalBytes.store(partialBytes, ordering: .relaxed)
    phase.store(DuplicateProgress.Phase.comparing.rawValue, ordering: .relaxed)
    let partial = parallelMap(partialFiles) { self.partialHash($0) }
    guard !isCancelled else { return nil }

    var byPartial: [PartialKey: [Candidate]] = [:]
    for (i, digest) in partial.enumerated() {
      guard let digest else { continue }
      let c = partialFiles[i]
      byPartial[PartialKey(size: c.size, digest: digest), default: []].append(c)
    }
    let fullFiles = byPartial.values.filter { $0.count > 1 }.flatMap { $0 }

    // 3. Full hashes for what still collides.
    let fullBytes = fullFiles.reduce(UInt64(0)) { $0 + $1.size }
    totalBytes.store(partialBytes + fullBytes, ordering: .relaxed)
    phase.store(DuplicateProgress.Phase.hashing.rawValue, ordering: .relaxed)
    let full = parallelMap(fullFiles) { self.fullHash($0) }
    guard !isCancelled else { return nil }

    var byDigest: [String: [Candidate]] = [:]
    for (i, digest) in full.enumerated() {
      guard let digest else { continue }
      byDigest[digest, default: []].append(fullFiles[i])
    }

    // 4. Groups with private sizes, dropping ones that free nothing.
    var groups: [DuplicateGroup] = []
    for (digest, members) in byDigest where members.count > 1 {
      let files = members.map { c in
        DuplicateFile(
          path: c.path, size: c.size, allocatedSize: c.allocated,
          privateSize: FileMetadata.privateSize(c.path) ?? c.allocated,
          created: c.created, modified: c.modified)
      }
      .sorted { ($0.created, $0.path) < ($1.created, $1.path) }
      let privates = files.map(\.privateSize)
      let best = privates.reduce(0, +) - (privates.min() ?? 0)
      guard best >= options.minSize / 16 else { continue }
      groups.append(DuplicateGroup(id: digest, size: members[0].size, files: files))
    }
    let home = options.homePath
    groups.sort {
      $0.waste(keeping: $0.autoOriginal(home: home)) > $1.waste(keeping: $1.autoOriginal(home: home))
    }
    phase.store(DuplicateProgress.Phase.finished.rawValue, ordering: .relaxed)
    return isCancelled ? nil : groups
  }

  // MARK: - Candidates

  struct FileKey: Hashable {
    var device: Int32
    var inode: UInt64
  }

  struct Candidate: Sendable {
    var path: String
    var size: UInt64
    var allocated: UInt64
    var key: FileKey
    var created: Date
    var modified: Date
  }

  struct PartialKey: Hashable {
    var size: UInt64
    var digest: SHA256.Digest
  }

  /// Paths of candidate files in the tree, before any I/O.
  func candidatePaths() -> [String] {
    let tree = self.tree
    let home = options.homePath
    var excluded = Set<NodeID>()
    let excludedPaths =
      Self.systemPaths + options.excludedPaths + [home + "/Library", home + "/.Trash"]
    for path in excludedPaths {
      if let id = tree.find(path: path), id != FileTree.root { excluded.insert(id) }
    }
    // iCloud Drive lives in ~/Library but holds the user's documents.
    var roots: [NodeID] = [FileTree.root]
    let iCloud = home + "/Library/Mobile Documents"
    if !options.excludedPaths.contains(where: { iCloud == $0 || iCloud.hasPrefix($0 + "/") }),
      let id = tree.find(path: iCloud)
    {
      roots.append(id)
    }
    if options.excludedPaths.contains(where: {
      tree.rootPath == $0 || tree.rootPath.hasPrefix($0 + "/")
    }) {
      return []
    }

    let skipDir = FileTree.Flags([.package, .symlink, .denied, .removed]).rawValue
    let skipFile = FileTree.Flags([.directory, .symlink, .removed]).rawValue
    let dirFlag = FileTree.Flags.directory.rawValue
    var result: [String] = []
    var stack = roots
    while let dir = stack.popLast() {
      for child in tree.children(dir) {
        let flags = tree.flags[Int(child)]
        if flags & dirFlag != 0 {
          guard flags & skipDir == 0, !excluded.contains(child), tree.size(child) >= options.minSize
          else { continue }
          let name = tree.name(child)
          guard !name.hasPrefix("."), !Self.skippedNames.contains(name) else { continue }
          stack.append(child)
        } else if flags & skipFile == 0, tree.size(child) >= options.minSize {
          guard tree.name(child).first != "." else { continue }
          result.append(tree.path(child))
        }
      }
    }
    return result
  }

  private func collect() -> [Candidate] {
    var result: [Candidate] = []
    for path in candidatePaths() {
      if isCancelled { return [] }
      var st = stat()
      guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
      // Evicted iCloud files would be downloaded by reading them.
      guard st.st_flags & UInt32(SF_DATALESS) == 0 else { continue }
      let size = UInt64(max(0, st.st_size))
      guard size >= options.minSize else { continue }
      result.append(
        Candidate(
          path: path, size: size, allocated: UInt64(max(0, st.st_blocks)) * 512,
          key: FileKey(device: st.st_dev, inode: st.st_ino),
          created: Date(timespec: st.st_birthtimespec),
          modified: Date(timespec: st.st_mtimespec)))
    }
    return result
  }

  // MARK: - Hashing

  /// Maps `items` on up to `maxConcurrency` threads, preserving order.
  private func parallelMap<R: Sendable>(
    _ items: [Candidate], _ body: @Sendable (Candidate) -> R?
  ) -> [R?] {
    guard !items.isEmpty else { return [] }
    let results = Mutex([R?](repeating: nil, count: items.count))
    let next = Atomic<Int>(0)
    let workers = min(options.maxConcurrency, items.count)
    DispatchQueue.concurrentPerform(iterations: workers) { _ in
      while !self.isCancelled {
        let i = next.add(1, ordering: .relaxed).oldValue
        guard i < items.count else { return }
        let value = body(items[i])
        results.withLock { $0[i] = value }
      }
    }
    return results.withLock { $0 }
  }

  private func partialHash(_ c: Candidate) -> SHA256.Digest? {
    withFile(c.path) { fd, buffer in
      var hasher = SHA256()
      let chunk = Self.partialChunk
      let head = Int(min(UInt64(chunk), c.size))
      guard readFully(fd, buffer, count: head, offset: 0) == head else { return nil }
      hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<head]))
      var read = UInt64(head)
      if c.size > UInt64(chunk) {
        let tailStart = max(UInt64(chunk), c.size - UInt64(chunk))
        let tail = Int(c.size - tailStart)
        guard readFully(fd, buffer, count: tail, offset: off_t(tailStart)) == tail else {
          return nil
        }
        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<tail]))
        read += UInt64(tail)
      }
      hashedBytes.add(read, ordering: .relaxed)
      return hasher.finalize()
    }
  }

  private func fullHash(_ c: Candidate) -> String? {
    withFile(c.path) { fd, buffer in
      var hasher = SHA256()
      var offset: UInt64 = 0
      while offset < c.size {
        if isCancelled { return nil }
        let want = Int(min(UInt64(Self.fullChunk), c.size - offset))
        let got = readFully(fd, buffer, count: want, offset: off_t(offset))
        guard got == want else { return nil }
        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<got]))
        offset += UInt64(got)
        hashedBytes.add(UInt64(got), ordering: .relaxed)
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
  }

  private func withFile<R>(
    _ path: String, _ body: (Int32, UnsafeMutableRawBufferPointer) -> R?
  ) -> R? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    _ = fcntl(fd, F_NOCACHE, 1)
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.fullChunk, alignment: 16)
    defer { buffer.deallocate() }
    return body(fd, buffer)
  }

  private func readFully(
    _ fd: Int32, _ buffer: UnsafeMutableRawBufferPointer, count: Int, offset: off_t
  ) -> Int {
    var done = 0
    while done < count {
      let n = pread(fd, buffer.baseAddress! + done, count - done, offset + off_t(done))
      if n < 0 && errno == EINTR { continue }
      guard n > 0 else { break }
      done += n
    }
    return done
  }
}

extension Date {
  fileprivate init(timespec ts: timespec) {
    self.init(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9)
  }
}
