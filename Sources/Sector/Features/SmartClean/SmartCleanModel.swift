import AppKit
import Foundation
import Observation
import SectorCore

/// Smart Clean: finds safe-to-remove categories (Xcode caches, stale
/// node_modules, Docker, simulators, app caches, Trash, logs, old
/// downloads) and runs the cleanup.
///
/// Contract other screens rely on:
/// - `reclaimableBytes` — total of safe categories, shown in the sidebar
///   badge, the overview card and the menu bar.
/// - `analyze()` — (re)computes categories from `app.tree`.
/// - `invalidate()` — called by `AppModel` after a new scan.
/// - `startCleaning()` — cleans the safe selection right away (menu bar
///   "Очистить"); the Smart Clean screen shows its progress.
@Observable @MainActor
final class SmartCleanModel {
  /// The three states of the Smart Clean screen.
  enum Phase: Equatable {
    /// Categories with selection (SmartClean mock).
    case review
    /// Progress ring and per-category rows (Cleaning mock).
    case cleaning
    /// Summary with confetti (Done mock).
    case done
  }

  /// A cleanup in flight or just finished.
  struct Run {
    var steps: [CleanupStep]
    var progress: CleanupProgress
    var plannedBytes: UInt64
    var availableBefore: UInt64
    var result: CleanupResult?

    var isFinished: Bool { result != nil }
    var isPaused: Bool { progress.isPaused && result == nil }

    /// 0…1, by bytes freed.
    var fraction: Double {
      if isFinished { return 1 }
      guard plannedBytes > 0 else { return 0 }
      return min(1, Double(progress.freedBytes) / Double(plannedBytes))
    }

    /// Seconds left at the current rate, once there is enough to judge.
    var remaining: TimeInterval? {
      guard !isFinished, progress.elapsed > 0.6, progress.freedBytes > 0 else { return nil }
      let rate = Double(progress.freedBytes) / progress.elapsed
      let left = Double(plannedBytes) - Double(progress.freedBytes)
      return max(0, left / rate)
    }
  }

  /// What the Done screen shows.
  struct Summary: Equatable {
    var freedBytes: UInt64
    var objectsRemoved: Int
    var categoriesCleaned: Int
    var availableBefore: UInt64
    var availableAfter: UInt64
    var totalCapacity: UInt64
    var duration: TimeInterval
    /// Extra days before the disk fills at the recent trend.
    var daysGained: Int?
  }

  @ObservationIgnored unowned let app: AppModel

  private(set) var categories: [CleanupCategory] = []
  private(set) var reclaimableBytes: UInt64 = 0
  private(set) var isAnalyzing = false
  /// False until the first analysis finished.
  private(set) var hasAnalyzed = false

  /// Selected item IDs.
  private(set) var selection: Set<String> = []
  /// The category whose items are shown (one at a time, as in the mock).
  var expanded: CleanupCategory.Kind?

  private(set) var phase: Phase = .review
  private(set) var run: Run?
  private(set) var summary: Summary?

  @ObservationIgnored private var knownIDs: Set<String> = []
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var pendingAnalysis: Task<Void, Never>?
  @ObservationIgnored private var runner: CleanupRunner?
  @ObservationIgnored private var pollTask: Task<Void, Never>?

  init(app: AppModel) {
    self.app = app
    observeTree()
  }

  // MARK: - Analysis

  func invalidate() {
    scheduleAnalysis()
  }

  /// Re-analyzes whenever the tree changes (new scan, removals elsewhere).
  private func observeTree() {
    withObservationTracking {
      _ = app.treeVersion
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.observeTree()
        self?.scheduleAnalysis()
      }
    }
  }

  /// Coalesces bursts of invalidations into one analysis.
  private func scheduleAnalysis() {
    // Never swap categories under a running cleanup; `finish` catches up.
    guard runner == nil else { return }
    pendingAnalysis?.cancel()
    pendingAnalysis = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      await self?.analyze()
    }
  }

  func analyze() async {
    generation += 1
    let current = generation
    isAnalyzing = true
    let context = makeContext()

    // File rules are fast and publish first; Docker and simulators follow
    // when their CLIs answer.
    let tools = Task.detached(priority: .userInitiated) {
      await CleanupAnalyzer.analyzeTools(context)
    }
    let files = await Task.detached(priority: .userInitiated) {
      CleanupAnalyzer.analyzeFiles(context)
    }.value
    guard current == generation else { return }
    let previousTools = categories.filter { $0.kind == .docker || $0.kind == .simulators }
    publish(files + previousTools)

    let toolCategories = await tools.value
    guard current == generation else { return }
    publish(files + toolCategories)
    isAnalyzing = false
    hasAnalyzed = true
  }

  private func makeContext() -> CleanupContext {
    let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    return CleanupContext(
      tree: app.tree, minimumAgeDays: app.settings.minimumAgeDays,
      exclusions: app.settings.exclusions, runningBundleIDs: running,
      excludedBundleIDs: Set([Bundle.main.bundleIdentifier].compactMap { $0 }),
      appURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
  }

  /// Installs new categories, keeping the user's choices for items that
  /// are still there and preselecting safe items that are new.
  private func publish(_ new: [CleanupCategory]) {
    let sorted = CleanupAnalyzer.sorted(new)
    let ids = Set(sorted.flatMap { $0.items.map(\.id) })
    let safeIDs = Set(sorted.flatMap { $0.safeItems.map(\.id) })
    selection = selection.intersection(ids).union(safeIDs.subtracting(knownIDs))
    knownIDs = ids
    if !hasAnalyzed, expanded == nil { expanded = sorted.first?.kind }
    if let expanded, !sorted.contains(where: { $0.kind == expanded }) { self.expanded = nil }
    categories = sorted
    reclaimableBytes = safeIDs.isEmpty
      ? 0 : sorted.flatMap(\.safeItems).reduce(0) { $0 + $1.size }
  }

  // MARK: - Selection

  enum Toggle { case on, off, mixed }

  var foundBytes: UInt64 { categories.reduce(0) { $0 + $1.size } }

  var selectedBytes: UInt64 {
    categories.reduce(0) { total, category in
      total + category.items.reduce(0) { $0 + (selection.contains($1.id) ? $1.size : 0) }
    }
  }

  var selectedCategoryCount: Int { categories.filter { state(of: $0) != .off }.count }

  func isSelected(_ item: CleanupItem) -> Bool { selection.contains(item.id) }

  func selectedBytes(in category: CleanupCategory) -> UInt64 {
    category.items.reduce(0) { $0 + (selection.contains($1.id) ? $1.size : 0) }
  }

  func state(of category: CleanupCategory) -> Toggle {
    let count = category.items.filter { selection.contains($0.id) }.count
    if count == 0 { return .off }
    return count == category.items.count ? .on : .mixed
  }

  /// The category switch: off clears it; on picks its safe items (all of
  /// them for "Проверьте" categories, where the user opts in knowingly).
  func toggle(_ category: CleanupCategory) {
    let ids = category.items.map(\.id)
    if state(of: category) == .off {
      let safe = category.safeItems.map(\.id)
      selection.formUnion(safe.isEmpty ? ids : safe)
    } else {
      selection.subtract(ids)
    }
  }

  func toggle(_ item: CleanupItem) {
    if selection.contains(item.id) {
      selection.remove(item.id)
    } else {
      selection.insert(item.id)
    }
  }

  /// "Выбрать безопасное".
  func selectSafe() {
    selection = Set(categories.flatMap { $0.safeItems.map(\.id) })
  }

  var isSafeSelection: Bool { selection == Set(categories.flatMap { $0.safeItems.map(\.id) }) }

  func isSelected(_ kind: CleanupCategory.Kind) -> Bool {
    categories.first { $0.kind == kind }.map { state(of: $0) != .off } ?? false
  }

  // MARK: - Cleaning

  /// Cleans the safe selection right away (menu bar "Очистить").
  func startCleaning() {
    guard phase != .cleaning else { return }
    app.route = .smartClean
    Task {
      if !hasAnalyzed { await analyze() }
      selectSafe()
      cleanSelection()
    }
  }

  /// Cleans whatever is selected on the screen.
  func cleanSelection() {
    guard phase != .cleaning else { return }
    let steps = categories.compactMap { category -> CleanupStep? in
      let items = category.items.filter { selection.contains($0.id) }
      return items.isEmpty ? nil : CleanupStep(category: category, items: items)
    }
    guard !steps.isEmpty else { return }
    // Drop any analysis in flight: it must not swap categories mid-run.
    pendingAnalysis?.cancel()
    generation += 1
    isAnalyzing = false

    let runner = CleanupRunner(steps: steps)
    self.runner = runner
    run = Run(
      steps: steps, progress: runner.progress, plannedBytes: runner.plannedBytes,
      availableBefore: app.volume?.available ?? 0)
    summary = nil
    phase = .cleaning

    pollTask?.cancel()
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        self?.run?.progress = runner.progress
        try? await Task.sleep(for: .milliseconds(33))
      }
    }

    Task {
      let result = await runner.run()
      pollTask?.cancel()
      guard self.runner === runner else { return }
      finish(result, runner: runner)
    }
  }

  private func finish(_ result: CleanupResult, runner: CleanupRunner) {
    run?.progress = runner.progress
    run?.result = result

    let removed = result.outcome.removed
    if !removed.isEmpty {
      app.applyRemoval(result.outcome)
      let detail =
        Plural.format(result.cleanedKinds.count, "категория", "категории", "категорий") + " · "
        + Plural.format(result.objectsRemoved, "объект", "объекта", "объектов")
      app.recordCleanup(
        CleanupRecord(
          source: .smartClean, title: String(localized: "Умная очистка"), detail: detail,
          mode: removed.contains { $0.trashedPath != nil } ? .trash : .permanent, items: removed))
    }

    let before = run?.availableBefore ?? 0
    let total = app.volume?.total ?? 0
    var daysGained: Int?
    if let trend = app.history.dailyTrend(), trend < 0, result.freedBytes > 0 {
      let days = Int((Double(result.freedBytes) / -trend).rounded())
      daysGained = days > 0 ? days : nil
    }
    summary = Summary(
      freedBytes: result.freedBytes, objectsRemoved: result.objectsRemoved,
      categoriesCleaned: result.cleanedKinds.count, availableBefore: before,
      availableAfter: total > 0 ? min(total, before + result.freedBytes) : before + result.freedBytes,
      totalCapacity: total, duration: result.duration, daysGained: daysGained)

    // The ring stays on screen, finished, until "Посмотреть итог"; fresh
    // categories are ready for when the user returns to the review.
    self.runner = nil
    scheduleAnalysis()
  }

  /// "Остановить".
  func pause() {
    runner?.pause()
    if let runner { run?.progress = runner.progress }
  }

  /// "Продолжить".
  func resume() {
    runner?.resume()
    if let runner { run?.progress = runner.progress }
  }

  /// "Завершить" while paused: stops after the current file.
  func stop() {
    runner?.cancel()
  }

  /// "Посмотреть итог".
  func showSummary() {
    guard run?.isFinished == true else { return }
    phase = .done
  }

  /// Leaves the Done state ("Готово", "Открыть историю", navigating away).
  func dismissSummary(to route: Route? = nil) {
    guard phase != .cleaning || run?.isFinished == true else { return }
    phase = .review
    run = nil
    if let route { app.route = route }
  }
}
