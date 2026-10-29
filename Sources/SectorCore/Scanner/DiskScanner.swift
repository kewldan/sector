import Darwin
import Foundation
import Synchronization

/// Live counters a UI can poll while a scan runs.
public struct ScanProgress: Sendable, Equatable {
  public var bytes: UInt64 = 0
  public var files: Int = 0
  public var directories: Int = 0
  public var deniedDirectories: Int = 0
  public var currentPath: String = ""
  public var elapsed: TimeInterval = 0
  public var isPaused = false

  public init() {}

  public init(
    bytes: UInt64, files: Int, directories: Int, deniedDirectories: Int, currentPath: String,
    elapsed: TimeInterval, isPaused: Bool
  ) {
    self.bytes = bytes
    self.files = files
    self.directories = directories
    self.deniedDirectories = deniedDirectories
    self.currentPath = currentPath
    self.elapsed = elapsed
    self.isPaused = isPaused
  }
}

/// How hard the scanner may push the machine.
public enum ScanLoad: String, Sendable, CaseIterable, Codable {
  case gentle, balanced, maximum

  var threadCount: Int {
    let cores = ProcessInfo.processInfo.activeProcessorCount
    switch self {
    case .gentle: return 2
    case .balanced: return max(2, cores / 2)
    case .maximum: return max(4, cores * 2)
    }
  }

  var qos: QualityOfService {
    switch self {
    case .gentle: return .utility
    case .balanced, .maximum: return .userInitiated
    }
  }
}

/// Parallel directory scanner built on `getattrlistbulk(2)`, which returns
/// the attributes of a whole directory in a few syscalls instead of one
/// `stat` per entry.
///
/// Mount points below the root are skipped, so scanning `/` counts the
/// system and data volumes once (firmlinks are followed transparently) and
/// never wanders into external drives.
public final class DiskScanner: @unchecked Sendable {
  public let root: URL
  public let load: ScanLoad

  private let queue = WorkQueue()
  private let storage = Mutex(TreeStorage(reserving: 1 << 16))
  private let seenHardLinks = Mutex(Set<UInt64>())
  private let denied = Mutex([String]())
  private let currentPath = Mutex("")

  private let bytes = Atomic<UInt64>(0)
  private let files = Atomic<Int>(0)
  private let directories = Atomic<Int>(0)
  private let deniedCount = Atomic<Int>(0)
  private let cancelled = Atomic<Bool>(false)

  private var startTime = Date()
  private let pausedTime = Mutex<(total: TimeInterval, since: Date?)>((0, nil))

  /// Directories never entered; reported as denied. Used without Full Disk
  /// Access for locations where opening would only raise a privacy prompt.
  public let skipPaths: Set<String>

  public init(root: URL, load: ScanLoad = .balanced, skipPaths: Set<String> = []) {
    self.root = root.standardizedFileURL
    self.load = load
    self.skipPaths = skipPaths
  }

  // MARK: - Control

  public var progress: ScanProgress {
    let paused = pausedTime.withLock { $0 }
    var elapsed = Date().timeIntervalSince(startTime) - paused.total
    if let since = paused.since { elapsed -= Date().timeIntervalSince(since) }
    return ScanProgress(
      bytes: bytes.load(ordering: .relaxed),
      files: files.load(ordering: .relaxed),
      directories: directories.load(ordering: .relaxed),
      deniedDirectories: deniedCount.load(ordering: .relaxed),
      currentPath: currentPath.withLock { $0 },
      elapsed: max(0, elapsed),
      isPaused: paused.since != nil)
  }

  /// Paths of directories the scanner was not allowed to read.
  public var deniedPaths: [String] { denied.withLock { $0 } }

  public func pause() {
    pausedTime.withLock { if $0.since == nil { $0.since = Date() } }
    queue.setPaused(true)
  }

  public func resume() {
    pausedTime.withLock {
      if let since = $0.since {
        $0.total += Date().timeIntervalSince(since)
        $0.since = nil
      }
    }
    queue.setPaused(false)
  }

  public func cancel() {
    cancelled.store(true, ordering: .relaxed)
    queue.cancel()
  }

  public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

  // MARK: - Running

  /// Scans on dedicated threads and returns the finished tree, or nil if
  /// the scan was cancelled.
  public func scan() async -> FileTree? {
    await withCheckedContinuation { continuation in
      let thread = Thread { continuation.resume(returning: self.run()) }
      thread.qualityOfService = load.qos
      thread.start()
    }
  }

  /// Blocking variant of `scan()`.
  public func run() -> FileTree? {
    startTime = Date()
    let rootPath = root.path
    var st = stat()
    let mtime = lstat(rootPath, &st) == 0 ? UInt32(clamping: st.st_mtimespec.tv_sec) : 0
    storage.withLock { $0.appendRoot(modified: mtime) }
    DiskScanner.raiseDescriptorLimit()
    queue.push([WorkItem(node: 0, path: rootPath)])

    let threadCount = load.threadCount
    let running = Atomic<Int>(threadCount)
    let exited = DispatchSemaphore(value: 0)
    for index in 0..<threadCount {
      let thread = Thread { [self] in
        worker(index)
        running.subtract(1, ordering: .relaxed)
        exited.signal()
      }
      thread.qualityOfService = load.qos
      thread.stackSize = 1 << 20
      thread.start()
    }
    // Wait for every worker, except ones stuck opening a directory once the
    // queue gave up on them (see `WorkQueue.pop`).
    while true {
      _ = exited.wait(timeout: .now() + 0.25)
      let left = running.load(ordering: .relaxed)
      if left == 0 || (queue.isAbandoned && left <= queue.openingCount) { break }
    }

    if isCancelled { return nil }
    var finished = storage.withLock { s in
      for item in queue.stalledItems {
        s.flags[Int(item.node)] |= FileTree.Flags.denied.rawValue
      }
      let taken = s
      s = TreeStorage(reserving: 0)
      return taken
    }
    let stalled = queue.stalledItems
    if !stalled.isEmpty {
      deniedCount.add(stalled.count, ordering: .relaxed)
      denied.withLock { $0.append(contentsOf: stalled.map(\.path)) }
    }
    finished.aggregate()
    return FileTree(rootPath: rootPath, storage: finished)
  }

  private static func raiseDescriptorLimit() {
    var limit = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
    let wanted = rlim_t(maxOpenHandles + 1024)
    if limit.rlim_cur < wanted {
      limit.rlim_cur = min(wanted, limit.rlim_max)
      setrlimit(RLIMIT_NOFILE, &limit)
    }
  }

  // MARK: - Worker

  /// Directory descriptors kept open for `openat`; beyond this children fall
  /// back to opening by full path.
  private static let maxOpenHandles = 4096
  private let openHandles = HandleCounter()

  private func worker(_ index: Int) {
    let bufferSize = 256 * 1024
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
    defer { buffer.deallocate() }
    var batch = DirectoryBatch()
    var subdirs: [WorkItem] = []
    var processed = 0

    while let item = queue.pop() {
      batch.reset()
      subdirs.removeAll(keepingCapacity: true)
      let fd = list(item, worker: index, into: &batch, buffer: buffer, bufferSize: bufferSize)

      if !batch.entries.isEmpty {
        // A worker that was stuck opening its directory may come back after
        // the scan gave up on it; its results no longer have a tree to go to.
        guard
          let base = storage.withLock({ s -> Int32? in
            queue.isAbandoned ? nil : s.commit(batch, parent: item.node)
          })
        else {
          if fd >= 0 { close(fd) }
          break
        }
        var handle: DirectoryHandle?
        if fd >= 0, batch.entries.contains(where: \.isDirectory),
          openHandles.value < DiskScanner.maxOpenHandles
        {
          handle = DirectoryHandle(fd: fd, counter: openHandles)
        } else if fd >= 0 {
          close(fd)
        }
        for (k, entry) in batch.entries.enumerated() where entry.isDirectory {
          let start = Int(entry.nameOffset)
          let name = String(
            decoding: batch.names[start..<start + Int(entry.nameLength)], as: UTF8.self)
          let path = item.path == "/" ? "/" + name : item.path + "/" + name
          if skipPaths.contains(path) {
            skip(node: base + Int32(k), path: path)
            continue
          }
          subdirs.append(WorkItem(node: base + Int32(k), path: path, name: name, parent: handle))
        }
        queue.push(subdirs)
      } else if fd >= 0 {
        close(fd)
      }
      queue.finish()

      processed += 1
      if processed & 31 == 0 { currentPath.withLock { $0 = item.path } }
    }
  }

  private func skip(node: Int32, path: String) {
    deniedCount.add(1, ordering: .relaxed)
    denied.withLock { if $0.count < 1000 { $0.append(path) } }
    storage.withLock { $0.flags[Int(node)] |= FileTree.Flags.denied.rawValue }
  }

  /// Lists one directory into `batch`; returns its still-open descriptor, or
  /// -1 if it could not be opened.
  private func list(
    _ item: WorkItem, worker: Int, into batch: inout DirectoryBatch,
    buffer: UnsafeMutableRawPointer, bufferSize: Int
  ) -> Int32 {
    let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    // Opening a privacy-protected folder can block on a system prompt; the
    // queue watches how long each open takes.
    queue.beginOpen(worker: worker, item: item)
    let fd: Int32
    if let parent = item.parent {
      fd = item.name.withCString { openat(parent.fd, $0, flags) }
    } else {
      fd = open(item.path, flags)
    }
    let openErrno = errno
    queue.endOpen(worker: worker)
    errno = openErrno
    if queue.isAbandoned {
      if fd >= 0 { close(fd) }
      return -1
    }
    guard fd >= 0 else {
      if errno == EACCES || errno == EPERM {
        deniedCount.add(1, ordering: .relaxed)
        denied.withLock { if $0.count < 1000 { $0.append(item.path) } }
        storage.withLock { $0.flags[Int(item.node)] |= FileTree.Flags.denied.rawValue }
      }
      return -1
    }
    directories.add(1, ordering: .relaxed)

    var request = BulkAttributes.request
    var fileBytes: UInt64 = 0
    var fileCount = 0
    while true {
      let n = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
      if n <= 0 { break }
      var entry = buffer
      for _ in 0..<n {
        let length = Int(entry.loadUnaligned(as: UInt32.self))
        if let parsed = BulkAttributes.parse(entry) {
          append(parsed, to: &batch, bytes: &fileBytes, files: &fileCount)
        }
        entry += length
      }
    }
    if fileCount > 0 {
      bytes.add(fileBytes, ordering: .relaxed)
      files.add(fileCount, ordering: .relaxed)
    }
    return fd
  }

  private func append(
    _ e: BulkAttributes.Entry, to batch: inout DirectoryBatch, bytes: inout UInt64,
    files: inout Int
  ) {
    var flags: UInt8 = 0
    var size: UInt64 = 0
    switch e.type {
    case BulkAttributes.typeDirectory:
      if e.isMountPoint { return }
      flags |= FileTree.Flags.directory.rawValue
      if BulkAttributes.isPackage(e.name) { flags |= FileTree.Flags.package.rawValue }
    case BulkAttributes.typeSymlink:
      flags |= FileTree.Flags.symlink.rawValue
      size = e.allocatedSize
    default:
      size = e.allocatedSize
      if e.linkCount > 1 {
        let first = seenHardLinks.withLock { $0.insert(e.fileID).inserted }
        if !first { size = 0 }
      }
    }
    if e.isHidden { flags |= FileTree.Flags.hidden.rawValue }
    if flags & FileTree.Flags.directory.rawValue == 0 {
      bytes &+= size
      files += 1
    }

    let nameLength = min(e.name.count, Int(UInt16.max))
    batch.entries.append(
      DirectoryBatch.Entry(
        size: size, modified: e.modified, nameOffset: UInt32(batch.names.count),
        nameLength: UInt16(nameLength), flags: flags))
    batch.names.append(contentsOf: e.name.prefix(nameLength))
  }
}

struct WorkItem {
  var node: Int32
  var path: String
  var name: String = ""
  /// Open parent directory, so the child is opened with `openat` and the
  /// kernel resolves one component instead of the whole path.
  var parent: DirectoryHandle?
}

final class HandleCounter: @unchecked Sendable {
  private let count = Atomic<Int>(0)
  var value: Int { count.load(ordering: .relaxed) }
  func increment() { count.add(1, ordering: .relaxed) }
  func decrement() { count.subtract(1, ordering: .relaxed) }
}

/// Reference-counted directory descriptor, closed once the last child that
/// needs it has been opened.
final class DirectoryHandle: @unchecked Sendable {
  let fd: Int32
  private let counter: HandleCounter

  init(fd: Int32, counter: HandleCounter) {
    self.fd = fd
    self.counter = counter
    counter.increment()
  }

  deinit {
    close(fd)
    counter.decrement()
  }
}

/// LIFO work stack shared by scanner threads. Depth-first order keeps the
/// number of pending paths small and directory metadata warm in cache.
///
/// It also watches directory opens: when the only work left is opens that
/// have been blocked for `stallTimeout` (a privacy prompt nobody answered, a
/// hung network mount), it gives up on them so the scan can finish.
final class WorkQueue: @unchecked Sendable {
  private let condition = NSCondition()
  private var stack: [WorkItem] = []
  private var outstanding = 0
  private var paused = false
  private var cancelled = false
  private var abandoned = false
  private var opening: [Int: (item: WorkItem, since: Date)] = [:]
  private var stalled: [WorkItem] = []
  let stallTimeout: TimeInterval

  init(stallTimeout: TimeInterval = 4) {
    self.stallTimeout = stallTimeout
  }

  func push(_ items: [WorkItem]) {
    guard !items.isEmpty else { return }
    condition.lock()
    stack.append(contentsOf: items)
    outstanding += items.count
    if items.count > 1 { condition.broadcast() } else { condition.signal() }
    condition.unlock()
  }

  /// Next directory to scan; nil once all work is done, cancelled or
  /// abandoned.
  func pop() -> WorkItem? {
    condition.lock()
    defer { condition.unlock() }
    while !cancelled && !abandoned && (paused || (stack.isEmpty && outstanding > 0)) {
      if !paused && stack.isEmpty && outstanding > 0 {
        let now = Date()
        let stuck = opening.values.filter { now.timeIntervalSince($0.since) > stallTimeout }
        if stuck.count == outstanding {
          abandoned = true
          stalled = stuck.map(\.item)
          condition.broadcast()
          break
        }
      }
      condition.wait(until: Date().addingTimeInterval(0.5))
    }
    if cancelled || abandoned { return nil }
    return stack.popLast()
  }

  /// Marks one popped item as fully processed (its children already pushed).
  func finish() {
    condition.lock()
    outstanding -= 1
    if outstanding == 0 { condition.broadcast() }
    condition.unlock()
  }

  func beginOpen(worker: Int, item: WorkItem) {
    condition.lock()
    opening[worker] = (item, Date())
    condition.unlock()
  }

  func endOpen(worker: Int) {
    condition.lock()
    opening[worker] = nil
    condition.unlock()
  }

  var isAbandoned: Bool {
    condition.lock()
    defer { condition.unlock() }
    return abandoned
  }

  var openingCount: Int {
    condition.lock()
    defer { condition.unlock() }
    return opening.count
  }

  /// Directories given up on, valid once `isAbandoned`.
  var stalledItems: [WorkItem] {
    condition.lock()
    defer { condition.unlock() }
    return stalled
  }

  func setPaused(_ value: Bool) {
    condition.lock()
    paused = value
    condition.broadcast()
    condition.unlock()
  }

  func cancel() {
    condition.lock()
    cancelled = true
    condition.broadcast()
    condition.unlock()
  }
}
