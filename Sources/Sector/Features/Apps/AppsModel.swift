import AppKit
import Foundation
import Observation
import SectorCore

/// Installed applications with their related data.
///
/// Contract: `invalidate()` is called by `AppModel` after a new scan; the
/// screen calls `startIfNeeded()` when it appears.
@Observable @MainActor
final class AppsModel {
  enum State: Equatable {
    case idle, loading, ready
  }

  enum Sort: String, CaseIterable, Identifiable {
    case size, age
    var id: String { rawValue }
  }

  @ObservationIgnored unowned let app: AppModel

  private(set) var state: State = .idle
  private(set) var apps: [InstalledApp] = []
  /// Bundle paths of running apps.
  private(set) var running: Set<String> = []
  private(set) var generation = 0
  var sort: Sort = .size
  var selectedID: String?
  /// Related items the user unchecked, by path.
  var unchecked: Set<String> = []

  @ObservationIgnored private var loadID = UUID()

  init(app: AppModel) {
    self.app = app
  }

  func invalidate() {
    loadID = UUID()
    state = .idle
    apps = []
    unchecked = []
    generation += 1
  }

  // MARK: - Loading

  func startIfNeeded() {
    refreshRunning()
    guard state == .idle else { return }
    load()
  }

  func load() {
    let id = UUID()
    loadID = id
    state = .loading
    let lookup = Self.sizeLookup(app.tree)
    Task {
      let found = await Task.detached(priority: .userInitiated) {
        AppInventory().apps(sizeOf: lookup)
      }.value
      guard self.loadID == id else { return }
      self.apps = found
      if !found.contains(where: { $0.id == self.selectedID }) {
        self.selectedID = self.sorted.first?.id
      }
      self.state = .ready
    }
  }

  /// Sizes from the scan, so the list needs no extra disk walk.
  private static func sizeLookup(_ tree: FileTree?) -> AppInventory.SizeLookup? {
    guard let tree else { return nil }
    return { path in
      guard let id = tree.find(path: path), !tree.flags(id).contains(.denied) else { return nil }
      return tree.size(id)
    }
  }

  // MARK: - Derived

  var sorted: [InstalledApp] {
    switch sort {
    case .size:
      return apps.sorted { ($0.totalSize, $1.name) > ($1.totalSize, $0.name) }
    case .age:
      // Never-opened apps first, then the longest unused.
      return apps.sorted { a, b in
        switch (a.lastUsed, b.lastUsed) {
        case (nil, nil): return a.totalSize > b.totalSize
        case (nil, _): return true
        case (_, nil): return false
        case let (x?, y?): return x < y
        }
      }
    }
  }

  var selected: InstalledApp? {
    apps.first { $0.id == selectedID } ?? sorted.first
  }

  var totalSize: UInt64 { apps.reduce(0) { $0 + $1.totalSize } }

  func checkedRelated(_ item: InstalledApp) -> [AppRelatedItem] {
    item.related.filter { !unchecked.contains($0.id) }
  }

  func isChecked(_ related: AppRelatedItem) -> Bool { !unchecked.contains(related.id) }

  func setChecked(_ related: AppRelatedItem, _ on: Bool) {
    if on { unchecked.remove(related.id) } else { unchecked.insert(related.id) }
  }

  /// Bytes "Удалить полностью" frees: the bundle plus checked data.
  func removalSize(_ item: InstalledApp) -> UInt64 {
    item.size + checkedRelated(item).reduce(0) { $0 + $1.size }
  }

  // MARK: - Running apps

  func refreshRunning() {
    running = Set(
      NSWorkspace.shared.runningApplications.compactMap {
        $0.bundleURL?.standardizedFileURL.path
      })
  }

  func isRunning(_ item: InstalledApp) -> Bool {
    running.contains(item.url.standardizedFileURL.path)
  }

  func quit(_ item: InstalledApp) {
    let path = item.url.standardizedFileURL.path
    for running in NSWorkspace.shared.runningApplications
    where running.bundleURL?.standardizedFileURL.path == path {
      running.terminate()
    }
  }

  // MARK: - Removal

  /// "Удалить полностью": the bundle and its checked data.
  func removeCompletely(_ item: InstalledApp) {
    guard !isRunning(item) else { return }
    var items = [DeletionItem(url: item.url, size: item.size)]
    items += checkedRelated(item).map { DeletionItem(url: $0.url, size: $0.size) }
    app.requestDeletion(
      DeletionRequest(
        items: items, source: .apps, recordTitle: item.name,
        onComplete: { [weak self] outcome in self?.applyRemoval(outcome, of: item) }))
  }

  /// "Сбросить данные": only the checked data; the app stays.
  func resetData(_ item: InstalledApp) {
    guard !isRunning(item) else { return }
    let items = checkedRelated(item).map { DeletionItem(url: $0.url, size: $0.size) }
    app.requestDeletion(
      DeletionRequest(
        items: items, source: .apps, recordTitle: item.name,
        onComplete: { [weak self] outcome in self?.applyRemoval(outcome, of: item) }))
  }

  private func applyRemoval(_ outcome: RemovalOutcome, of item: InstalledApp) {
    let removed = Set(outcome.removed.map(\.originalPath))
    guard !removed.isEmpty else { return }
    unchecked.subtract(removed)
    if removed.contains(item.url.path) {
      let order = sorted
      let index = order.firstIndex { $0.id == item.id } ?? 0
      apps.removeAll { $0.id == item.id }
      if selectedID == item.id {
        let rest = order.filter { $0.id != item.id }
        selectedID = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
      }
      return
    }
    // Data reset: drop what is gone and re-measure what remains.
    if let i = apps.firstIndex(where: { $0.id == item.id }) {
      apps[i].related.removeAll { removed.contains($0.url.path) }
    }
    let url = item.url
    let lookup = Self.sizeLookup(app.tree)
    let id = loadID
    Task {
      let fresh = await Task.detached(priority: .utility) {
        AppInventory().app(at: url, sizeOf: lookup)
      }.value
      guard self.loadID == id, let fresh,
        let i = self.apps.firstIndex(where: { $0.id == item.id })
      else { return }
      self.apps[i] = fresh
    }
  }
}
