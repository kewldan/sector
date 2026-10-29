import Darwin
import Foundation
import Synchronization

/// One category's share of a cleanup run.
public struct CleanupStep: Sendable, Identifiable {
  public var kind: CleanupCategory.Kind
  public var title: String
  public var mode: RemovalMode
  public var items: [CleanupItem]

  public var id: CleanupCategory.Kind { kind }
  public var plannedBytes: UInt64 { items.reduce(0) { $0 + $1.size } }
  public var plannedObjects: Int { items.reduce(0) { $0 + $1.objectCount } }

  public init(category: CleanupCategory, items: [CleanupItem]) {
    kind = category.kind
    title = category.shortTitle
    mode = category.mode
    self.items = items
  }
}

/// Live state of a run, polled by the UI.
public struct CleanupProgress: Sendable, Equatable {
  public enum State: Sendable, Equatable { case pending, active, done }

  public struct Step: Sendable, Equatable {
    public var state: State = .pending
    public var freedBytes: UInt64 = 0
    public var objectsDone = 0
    public var failures = 0
  }

  public var steps: [Step]
  public var freedBytes: UInt64 = 0
  public var objectsDone = 0
  /// Running time without pauses.
  public var elapsed: TimeInterval = 0
  public var isPaused = false
  public var isFinished = false

  public init(stepCount: Int) {
    steps = Array(repeating: Step(), count: stepCount)
  }
}

/// What a finished (or stopped) run did.
public struct CleanupResult: Sendable {
  public var outcome: RemovalOutcome
  /// Bytes actually freed, including partly removed folders.
  public var freedBytes: UInt64
  public var objectsRemoved: Int
  /// Categories where at least something was removed.
  public var cleanedKinds: [CleanupCategory.Kind]
  public var duration: TimeInterval
  public var wasCancelled: Bool
}

/// Removes the selected Smart Clean items step by step, reporting progress
/// per category. Pausable and cancellable between files.
///
/// Permanent removal walks folders physically: symlinks are unlinked, never
/// followed, mount points are not crossed, and nothing outside
/// `allowedRoot` (the home folder) is touched.
public final class CleanupRunner: @unchecked Sendable {
  public let steps: [CleanupStep]
  public let allowedRoot: URL

  private let state: Mutex<CleanupProgress>
  private let paused = Atomic<Bool>(false)
  private let cancelled = Atomic<Bool>(false)
  private let clock = Mutex<(start: Date?, pausedTotal: TimeInterval, pausedSince: Date?)>(
    (nil, 0, nil))

  public init(steps: [CleanupStep], allowedRoot: URL = URL(fileURLWithPath: NSHomeDirectory())) {
    self.steps = steps
    self.allowedRoot = allowedRoot
    state = Mutex(CleanupProgress(stepCount: steps.count))
  }

  public var plannedBytes: UInt64 { steps.reduce(0) { $0 + $1.plannedBytes } }
  public var plannedObjects: Int { steps.reduce(0) { $0 + $1.plannedObjects } }

  public var progress: CleanupProgress {
    var p = state.withLock { $0 }
    p.elapsed = elapsed
    p.isPaused = paused.load(ordering: .relaxed)
    return p
  }

  private var elapsed: TimeInterval {
    clock.withLock { c in
      guard let start = c.start else { return 0 }
      let now = Date()
      let pausedNow = c.pausedSince.map { now.timeIntervalSince($0) } ?? 0
      return now.timeIntervalSince(start) - c.pausedTotal - pausedNow
    }
  }

  public func pause() {
    guard !paused.exchange(true, ordering: .relaxed) else { return }
    clock.withLock { $0.pausedSince = Date() }
  }

  public func resume() {
    guard paused.exchange(false, ordering: .relaxed) else { return }
    clock.withLock { c in
      if let since = c.pausedSince { c.pausedTotal += Date().timeIntervalSince(since) }
      c.pausedSince = nil
    }
  }

  public func cancel() {
    cancelled.store(true, ordering: .relaxed)
    resume()
  }

  public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

  /// Runs on a dedicated thread and returns when done or cancelled.
  public func run() async -> CleanupResult {
    await withCheckedContinuation { continuation in
      let thread = Thread { continuation.resume(returning: self.runBlocking()) }
      thread.qualityOfService = .userInitiated
      thread.start()
    }
  }

  // MARK: - Execution

  private var outcome = RemovalOutcome()
  private var freedTotal: UInt64 = 0
  private var objectsTotal = 0
  private var cleaned: [CleanupCategory.Kind] = []

  func runBlocking() -> CleanupResult {
    clock.withLock { $0.start = Date() }
    for (index, step) in steps.enumerated() {
      guard !waitWhilePaused() else { break }
      update { $0.steps[index].state = .active }
      let before = outcome.removed.count
      let freedBefore = freedTotal
      for item in step.items {
        guard !waitWhilePaused() else { break }
        perform(item, mode: step.mode, step: index)
      }
      if outcome.removed.count > before || freedTotal > freedBefore { cleaned.append(step.kind) }
      if isCancelled { break }
      update { $0.steps[index].state = .done }
    }
    let duration = elapsed
    update { $0.isFinished = true }
    return CleanupResult(
      outcome: outcome, freedBytes: freedTotal, objectsRemoved: objectsTotal,
      cleanedKinds: cleaned, duration: duration, wasCancelled: isCancelled)
  }

  /// Blocks while paused; returns true when the run was cancelled.
  private func waitWhilePaused() -> Bool {
    while paused.load(ordering: .relaxed) && !isCancelled { usleep(50_000) }
    return isCancelled
  }

  private func update(_ body: (inout CleanupProgress) -> Void) {
    state.withLock { body(&$0) }
  }

  private func credit(step: Int, bytes: UInt64, objects: Int) {
    freedTotal &+= bytes
    objectsTotal += objects
    update {
      $0.freedBytes &+= bytes
      $0.objectsDone += objects
      $0.steps[step].freedBytes &+= bytes
      $0.steps[step].objectsDone += objects
    }
  }

  private func fail(_ url: URL, _ message: String, step: Int) {
    outcome.failed.append((url, message))
    update { $0.steps[step].failures += 1 }
  }

  private func perform(_ item: CleanupItem, mode: RemovalMode, step: Int) {
    switch item.target {
    case .files(let files):
      for file in files {
        guard !waitWhilePaused() else { return }
        switch mode {
        case .trash: trash(file, step: step)
        case .permanent: delete(file, step: step)
        }
      }
    case .dockerImages(let docker, let objects):
      for object in objects {
        guard !waitWhilePaused() else { return }
        runTool(
          docker, ["image", "rm"] + object.references, path: "docker://image/\(object.references[0])",
          size: object.size, objects: 1, step: step)
      }
    case .dockerVolumes(let docker, let objects):
      for object in objects {
        guard !waitWhilePaused() else { return }
        runTool(
          docker, ["volume", "rm"] + object.references,
          path: "docker://volume/\(object.references[0])", size: object.size, objects: 1, step: step)
      }
    case .simulators(let xcrun, let devices):
      for device in devices {
        guard !waitWhilePaused() else { return }
        guard isSafeTarget(device.directory) else {
          fail(device.directory, "outside the allowed folder", step: step)
          continue
        }
        runTool(
          xcrun, ["simctl", "delete", device.udid], path: device.directory.path, size: device.size,
          objects: max(1, device.fileCount), step: step)
      }
    }
  }

  private func runTool(
    _ executable: String, _ arguments: [String], path: String, size: UInt64, objects: Int,
    step: Int
  ) {
    let url = URL(fileURLWithPath: path)
    guard let result = CommandRunner.runBlocking(executable, arguments, timeout: 180),
      result.succeeded
    else {
      fail(url, "\(arguments.joined(separator: " ")) failed", step: step)
      return
    }
    outcome.removed.append(.init(originalPath: path, trashedPath: nil, size: size))
    credit(step: step, bytes: size, objects: objects)
  }

  private func trash(_ file: CleanupFile, step: Int) {
    guard isSafeTarget(file.url) else {
      fail(file.url, "outside the allowed folder", step: step)
      return
    }
    do {
      var resulting: NSURL?
      try FileManager().trashItem(at: file.url, resultingItemURL: &resulting)
      outcome.removed.append(
        .init(
          originalPath: file.url.path, trashedPath: (resulting as URL?)?.path, size: file.size))
      credit(step: step, bytes: file.size, objects: max(1, file.fileCount))
    } catch {
      fail(file.url, error.localizedDescription, step: step)
    }
  }

  /// Deletes a file or folder tree file by file, crediting progress as it
  /// goes. The item counts as removed only when nothing of it is left.
  private func delete(_ file: CleanupFile, step: Int) {
    let url = file.url
    let path = url.path
    guard isSafeTarget(url) else {
      fail(url, "outside the allowed folder", step: step)
      return
    }
    var st = stat()
    guard lstat(path, &st) == 0 else {
      // Already gone: reflect that in the tree, nothing to free.
      if errno == ENOENT {
        outcome.removed.append(.init(originalPath: path, trashedPath: nil, size: 0))
      }
      return
    }

    var freed: UInt64 = 0
    var lastError: Int32 = 0
    if (st.st_mode & S_IFMT) != S_IFDIR {
      if Self.unlinkRetrying(path) {
        let bytes = Self.reclaimable(st)
        freed = bytes
        credit(step: step, bytes: bytes, objects: 1)
      } else {
        lastError = errno
      }
    } else {
      FTSWalk.walk(path) { entry in
        if waitWhilePaused() { return false }
        switch entry.info {
        case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT, FTS_NSOK:
          if Self.unlinkRetrying(entry.path) {
            let bytes = entry.stat.map(Self.reclaimable) ?? 0
            freed &+= bytes
            credit(step: step, bytes: bytes, objects: 1)
          } else {
            lastError = errno
          }
        case FTS_DP:
          if !Self.rmdirRetrying(entry.path) && errno != ENOTEMPTY { lastError = errno }
        case FTS_DNR, FTS_ERR, FTS_NS:
          lastError = entry.error
        default:
          break
        }
        return true
      }
    }

    if lstat(path, &st) != 0 && errno == ENOENT {
      outcome.removed.append(.init(originalPath: path, trashedPath: nil, size: freed))
    } else if !isCancelled {
      fail(url, String(cString: strerror(lastError == 0 ? EPERM : lastError)), step: step)
    }
  }

  /// Bytes unlinking frees: nothing while other hard links remain.
  private static func reclaimable(_ st: stat) -> UInt64 {
    st.st_nlink > 1 ? 0 : UInt64(max(0, st.st_blocks)) * 512
  }

  /// `unlink`, making the parent writable once if permissions block it
  /// (read-only folders in caches and build products).
  private static func unlinkRetrying(_ path: String) -> Bool {
    if unlink(path) == 0 { return true }
    guard errno == EACCES || errno == EPERM else { return false }
    makeParentWritable(path)
    return unlink(path) == 0
  }

  private static func rmdirRetrying(_ path: String) -> Bool {
    if rmdir(path) == 0 { return true }
    guard errno == EACCES || errno == EPERM else { return false }
    makeParentWritable(path)
    return rmdir(path) == 0
  }

  private static func makeParentWritable(_ path: String) {
    let parent = (path as NSString).deletingLastPathComponent
    var st = stat()
    guard lstat(parent, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
      return
    }
    chmod(parent, (st.st_mode & 0o7777) | S_IRWXU)
  }

  /// Whether `url` is strictly inside `allowedRoot` (at least two levels
  /// down, through real folders) and not a protected path.
  func isSafeTarget(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.path
    guard !CleanupAnalyzer.isProtected(path),
      let root = Self.realPath(allowedRoot.path),
      let parent = Self.realPath((path as NSString).deletingLastPathComponent)
    else { return false }
    let name = (path as NSString).lastPathComponent
    guard !name.isEmpty, name != ".", name != ".." else { return false }
    return parent.hasPrefix(root.hasSuffix("/") ? root : root + "/")
  }

  private static func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}
