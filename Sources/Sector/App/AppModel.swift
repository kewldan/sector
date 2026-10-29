import AppKit
import Foundation
import Observation
import SectorCore

/// A file or folder offered for deletion in the confirmation sheet.
struct DeletionItem: Identifiable, Hashable {
  var id: URL { url }
  var url: URL
  var size: UInt64
  var name: String { url.lastPathComponent }
  /// Short type label shown in the file badge ("PVM", "BAK", "DMG").
  var kindLabel: String {
    let ext = url.pathExtension.uppercased()
    return ext.isEmpty ? (url.hasDirectoryPath ? "DIR" : "FILE") : String(ext.prefix(4))
  }
}

/// Everything the confirmation sheet needs; screens build one and call
/// `AppModel.requestDeletion`.
struct DeletionRequest: Identifiable {
  let id = UUID()
  var items: [DeletionItem]
  var source: CleanupSource
  /// Title of the History record ("Большие и старые файлы", "Docker.raw").
  var recordTitle: String
  /// Called on the main actor after removal finishes.
  var onComplete: (@MainActor (RemovalOutcome) -> Void)?

  var totalSize: UInt64 { items.reduce(0) { $0 + $1.size } }
}

/// Transient message with an optional undo, shown at the bottom of the window.
struct Toast: Identifiable, Equatable {
  let id = UUID()
  var text: String
  var undo: (@MainActor () -> Void)?

  static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// App-wide state: the current scan, the tree it produced, settings,
/// history and cross-screen requests. Feature screens keep their own models
/// (`SmartCleanModel`, `DuplicatesModel`, `AppsModel`) and reach shared
/// state through this one.
@Observable @MainActor
final class AppModel {
  enum Phase: Equatable {
    case welcome, permission, main
  }

  enum ScanState: Equatable {
    case idle
    case running
    case paused
    /// Finished; the scan screen shows its summary until the user moves on.
    case finished(duration: TimeInterval)
    case cancelled
  }

  let settings: AppSettings
  let history: HistoryStore

  var phase: Phase
  var route: Route = .overview
  /// True while the main window shows the scan screen instead of `route`.
  var showsScan = false

  private(set) var volume: VolumeInfo?
  private(set) var volumes: [VolumeInfo] = []
  private(set) var tree: FileTree?
  private(set) var breakdown: CategoryBreakdown?
  /// Bumped whenever the tree changes (removal, new scan); views that cache
  /// derived data compare it.
  private(set) var treeVersion = 0
  private(set) var historyVersion = 0

  private(set) var scanState: ScanState = .idle
  private(set) var scanProgress = ScanProgress()
  private(set) var deniedPaths: [String] = []
  private(set) var hasFullDiskAccess = DiskAccess.hasFullAccess
  private var scanner: DiskScanner?
  private var progressTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?

  var deletionRequest: DeletionRequest?
  var toast: Toast?

  @ObservationIgnored lazy var smartClean = SmartCleanModel(app: self)
  @ObservationIgnored lazy var duplicates = DuplicatesModel(app: self)
  @ObservationIgnored lazy var apps = AppsModel(app: self)

  init(settings: AppSettings = AppSettings(), history: HistoryStore = HistoryStore()) {
    self.settings = settings
    self.history = history
    phase = settings.onboarded ? .main : .welcome
    refreshVolume()
  }

  // MARK: - Volume

  func refreshVolume() {
    volumes = VolumeInfo.mounted()
    volume = VolumeInfo.startup()
    if let volume { history.sample(volume) }
  }

  func refreshDiskAccess() {
    hasFullDiskAccess = DiskAccess.hasFullAccess
  }

  /// Bytes used on the volume that the scan could not attribute to files:
  /// snapshots, other APFS volumes, protected folders and, for a home-only
  /// scan, everything outside the home folder.
  var unscannedBytes: UInt64 {
    guard let tree, let volume else { return 0 }
    let scanned = tree.size(FileTree.root)
    return volume.used > scanned ? volume.used - scanned : 0
  }

  // MARK: - Scanning

  var scanRoot: URL {
    switch settings.scanScope {
    case .startupDisk: return URL(fileURLWithPath: "/")
    case .home: return URL(fileURLWithPath: NSHomeDirectory())
    }
  }

  var isScanning: Bool { scanState == .running || scanState == .paused }

  /// Folders macOS guards with a privacy prompt (or denies outright) unless
  /// the app has Full Disk Access. Without it the scan skips them instead of
  /// stacking up system dialogs, and the overview explains what is missing.
  /// Desktop, Documents and Downloads are left in: one prompt each is the
  /// normal way to grant those.
  static var privacyProtectedPaths: Set<String> {
    let home = NSHomeDirectory()
    let library = home + "/Library"
    return Set(
      [
        "/Containers", "/Group Containers", "/Mail", "/Messages", "/Safari", "/Calendars",
        "/Reminders", "/Cookies", "/HomeKit", "/IdentityServices", "/Metadata/CoreSpotlight",
        "/Mobile Documents", "/Photos", "/Suggestions", "/Sharing", "/Biome", "/DuetExpertCenter",
        "/Application Support/AddressBook", "/Application Support/CallHistoryDB",
        "/Application Support/CallHistoryTransactions", "/Application Support/com.apple.TCC",
        "/Application Support/FileProvider", "/Application Support/Knowledge",
        "/Application Support/com.apple.sharedfilelist", "/Autosave Information",
        "/Accounts", "/Assistant/SiriVocabulary", "/PersonalizationPortrait", "/Trial",
        "/Caches/com.apple.Safari", "/Caches/CloudKit", "/Caches/com.apple.findmy.fmipcore",
        "/Caches/com.apple.HomeKit", "/Caches/com.apple.ap.adprivacyd",
        "/Caches/com.apple.containermanagerd", "/Caches/FamilyCircle",
      ].map { library + $0 }
        + [
          home + "/Movies/TV", home + "/Music/Music", home + "/Music/iTunes",
          home + "/Pictures/Photos Library.photoslibrary", home + "/.Trash",
        ])
  }

  /// Called once the main window appears: shows the cached tree right away
  /// and refreshes it in the background when stale, or scans from scratch.
  func launch() async {
    guard phase == .main, tree == nil, !isScanning else { return }
    let root = scanRoot.path
    let cached = await Task.detached(priority: .userInitiated) {
      FileTree.read(from: FileTree.defaultCacheURL)
    }.value
    guard let cached, cached.rootPath == root, tree == nil, !isScanning else {
      if tree == nil && !isScanning { startScan() }
      return
    }
    await install(cached)
    deniedPaths = await Task.detached(priority: .utility) {
      Array(cached.nodes { cached.flags($0).contains(.denied) }.prefix(1000).map(cached.path))
    }.value
    scanState = .finished(duration: 0)
    smartClean.invalidate()
    duplicates.invalidate()
    apps.invalidate()
    if Date().timeIntervalSince(cached.scannedAt) > 3600 { startScan(showScreen: false) }
  }

  func startScan(showScreen: Bool = true) {
    scanner?.cancel()
    refreshDiskAccess()
    let scanner = DiskScanner(
      root: scanRoot, load: settings.scanLoad,
      skipPaths: hasFullDiskAccess ? [] : Self.privacyProtectedPaths)
    self.scanner = scanner
    scanState = .running
    scanProgress = ScanProgress()
    if showScreen { showsScan = true }
    refreshVolume()

    progressTask?.cancel()
    progressTask = Task { [weak self] in
      while !Task.isCancelled {
        self?.scanProgress = scanner.progress
        try? await Task.sleep(for: .milliseconds(33))
      }
    }

    Task {
      let result = await scanner.scan()
      progressTask?.cancel()
      guard self.scanner === scanner else { return }
      scanProgress = scanner.progress
      deniedPaths = scanner.deniedPaths
      guard let result else {
        scanState = .cancelled
        return
      }
      await install(result)
      scheduleSave()
      scanState = .finished(duration: scanProgress.elapsed)
      smartClean.invalidate()
      duplicates.invalidate()
      apps.invalidate()
    }
  }

  func pauseScan() {
    scanner?.pause()
    scanState = .paused
  }

  func resumeScan() {
    scanner?.resume()
    scanState = .running
  }

  func cancelScan() {
    scanner?.cancel()
  }

  /// Leaves the scan screen for the results.
  func showResults() {
    showsScan = false
  }

  private func install(_ tree: FileTree) async {
    refreshVolume()
    let unscanned: UInt64 = {
      guard let volume else { return 0 }
      let scanned = tree.size(FileTree.root)
      return volume.used > scanned ? volume.used - scanned : 0
    }()
    let breakdown = await Task.detached(priority: .userInitiated) {
      CategoryBreakdown.compute(tree: tree, unscanned: unscanned)
    }.value
    self.tree = tree
    self.breakdown = breakdown
    treeVersion += 1
  }

  private func recomputeBreakdown() {
    guard let tree else { return }
    let unscanned = unscannedBytes
    Task {
      let b = await Task.detached(priority: .utility) {
        CategoryBreakdown.compute(tree: tree, unscanned: unscanned)
      }.value
      if self.tree === tree { self.breakdown = b }
    }
  }

  // MARK: - Removal

  /// Shows the confirmation sheet, or removes right away when the user
  /// turned confirmations off (globally, or for items in ~/Downloads).
  func requestDeletion(_ request: DeletionRequest) {
    guard !request.items.isEmpty else { return }
    let skipsSheet = settings.skipConfirmForDownloads && request.isInDownloads
    if settings.alwaysConfirm && !skipsSheet {
      deletionRequest = request
    } else {
      Task { await perform(request, mode: settings.moveToTrash ? .trash : .permanent) }
    }
  }

  /// Removes the request's items, updates the tree and records History.
  @discardableResult
  func perform(_ request: DeletionRequest, mode: RemovalMode) async -> RemovalOutcome {
    let items = request.items.map { RemovalItem(url: $0.url, size: $0.size) }
    let outcome = await FileRemover.remove(items, mode: mode)
    applyRemoval(outcome)
    if !outcome.removed.isEmpty {
      let count = outcome.removed.count
      let record = CleanupRecord(
        source: request.source, title: request.recordTitle,
        detail: Plural.format(count, "объект", "объекта", "объектов"), mode: mode, items: outcome.removed)
      history.add(record)
      historyVersion += 1
      var undo: (@MainActor () -> Void)?
      if mode == .trash {
        undo = { @MainActor [weak self] in
          _ = self?.restore(record)
        }
      }
      toast = Toast(
        text: String(localized: "Освобождено \(ByteFormat.string(outcome.freedBytes))"),
        undo: undo)
    }
    request.onComplete?(outcome)
    return outcome
  }

  /// Reflects removed paths in the tree and refreshes derived data.
  func applyRemoval(_ outcome: RemovalOutcome) {
    guard !outcome.removed.isEmpty else { return }
    if let tree {
      for removed in outcome.removed {
        if let id = tree.find(path: removed.originalPath) { tree.remove(id) }
      }
      treeVersion += 1
      recomputeBreakdown()
      scheduleSave()
    }
    refreshVolume()
  }

  /// Persists the tree a moment after it settles, off the main actor.
  private func scheduleSave() {
    guard let tree else { return }
    saveTask?.cancel()
    saveTask = Task {
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      await Task.detached(priority: .utility) {
        try? tree.write(to: FileTree.defaultCacheURL)
      }.value
    }
  }

  /// Tells History-dependent views that records changed outside `AppModel`.
  func historyDidChange() {
    historyVersion += 1
  }

  /// Records a cleanup performed outside `perform` (Smart Clean, Docker).
  func recordCleanup(_ record: CleanupRecord) {
    history.add(record)
    historyVersion += 1
  }

  /// Moves a record's items (or just `paths`) back from the Trash.
  @discardableResult
  func restore(_ record: CleanupRecord, paths: Set<String>? = nil) -> Int {
    var updated = record
    var restored = 0
    for item in record.items where paths?.contains(item.originalPath) ?? true {
      guard !updated.restoredPaths.contains(item.originalPath) else { continue }
      if (try? FileRemover.restore(item)) != nil {
        updated.restoredPaths.insert(item.originalPath)
        restored += 1
      }
    }
    history.update(updated)
    historyVersion += 1
    refreshVolume()
    if restored > 0 { toast = Toast(text: String(localized: "Восстановлено объектов: \(restored)")) }
    return restored
  }

  // MARK: - Finder

  func revealInFinder(_ urls: [URL]) {
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  func openFullDiskAccessSettings() {
    NSWorkspace.shared.open(DiskAccess.settingsURL)
  }
}
