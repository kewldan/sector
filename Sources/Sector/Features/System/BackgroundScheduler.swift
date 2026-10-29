import AppKit
import Observation
import SectorCore

/// Weekly background scan ("Сканировать в фоне · Раз в неделю") through
/// `NSBackgroundActivityScheduler`, so macOS picks an idle, plugged-in
/// moment. Runs only while Sector is open (it lives in the menu bar).
@MainActor
final class BackgroundScheduler {
  private static let interval: TimeInterval = 7 * 86_400
  private static let lastKey = "backgroundScan.last"

  private let model: AppModel
  private let notifications: NotificationService
  private var scheduler: NSBackgroundActivityScheduler?

  init(model: AppModel, notifications: NotificationService) {
    self.model = model
    self.notifications = notifications
  }

  func start() {
    reschedule()
    observeSetting()
    observeScans()
  }

  /// Remembers manual scans too, so a recent one postpones the weekly run
  /// across launches.
  private func observeScans() {
    withObservationTracking {
      _ = model.scanState
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if case .finished = self.model.scanState, let tree = self.model.tree,
          tree.rootPath == self.model.scanRoot.path
        {
          let stored = UserDefaults.standard.object(forKey: Self.lastKey) as? Date
          if stored.map({ tree.scannedAt > $0 }) ?? true {
            UserDefaults.standard.set(tree.scannedAt, forKey: Self.lastKey)
          }
        }
        self.observeScans()
      }
    }
  }

  private func observeSetting() {
    withObservationTracking {
      _ = model.settings.backgroundScan
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.reschedule()
        self?.observeSetting()
      }
    }
  }

  /// Date of the most recent scan we know about.
  private var lastScan: Date? {
    let stored = UserDefaults.standard.object(forKey: Self.lastKey) as? Date
    let tree = model.tree?.scannedAt
    switch (stored, tree) {
    case let (a?, b?): return max(a, b)
    default: return stored ?? tree
    }
  }

  private func reschedule() {
    scheduler?.invalidate()
    scheduler = nil
    guard model.settings.backgroundScan else { return }

    let due = lastScan.map { $0.addingTimeInterval(Self.interval) } ?? Date().addingTimeInterval(3600)
    let delay = max(15 * 60, due.timeIntervalSinceNow)
    let activity = NSBackgroundActivityScheduler(identifier: "com.kewldan.sector.weekly-scan")
    activity.repeats = false
    activity.interval = delay
    activity.tolerance = min(delay / 4, 6 * 3600)
    activity.qualityOfService = .utility
    activity.schedule { [weak self] completion in
      let done = CompletionBox(completion)
      Task { @MainActor [weak self] in
        guard let self else { return done.call(.finished) }
        let result = await self.run()
        done.call(result)
        if result == .finished { self.reschedule() }
      }
    }
    scheduler = activity
  }

  private func run() async -> NSBackgroundActivityScheduler.Result {
    guard model.settings.backgroundScan, model.phase == .main else { return .finished }
    guard !model.isScanning, scheduler?.shouldDefer != true else { return .deferred }
    // A recent manual scan counts as this week's.
    if let last = lastScan, Date().timeIntervalSince(last) < Self.interval - 86_400 {
      return .finished
    }

    let since = lastScan ?? Date().addingTimeInterval(-Self.interval)
    model.startScan(showScreen: false)
    while model.isScanning {
      try? await Task.sleep(for: .seconds(1))
    }
    guard case .finished = model.scanState, let tree = model.tree else { return .finished }
    UserDefaults.standard.set(tree.scannedAt, forKey: Self.lastKey)
    await notifications.reportNewLargeFiles(in: tree, since: since)
    return .finished
  }
}

/// Carries the scheduler's completion handler into the main-actor task.
private final class CompletionBox: @unchecked Sendable {
  private let completion: NSBackgroundActivityScheduler.CompletionHandler

  init(_ completion: @escaping NSBackgroundActivityScheduler.CompletionHandler) {
    self.completion = completion
  }

  func call(_ result: NSBackgroundActivityScheduler.Result) { completion(result) }
}
