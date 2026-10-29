import Foundation
import Observation
import SectorCore

/// Duplicate finder over the scanned tree.
///
/// Contract: `invalidate()` is called by `AppModel` after a new scan; the
/// screen calls `startIfNeeded()` when it appears, so hashing only runs once
/// the user opens it.
@Observable @MainActor
final class DuplicatesModel {
  enum State: Equatable {
    case idle, finding, cancelled, ready
  }

  /// Groups listed before "Все группы" expands the list.
  static let initialLimit = 100

  @ObservationIgnored unowned let app: AppModel

  private(set) var state: State = .idle
  private(set) var progress = DuplicateProgress()
  /// Sorted by reclaimable bytes, largest first.
  private(set) var groups: [DuplicateGroup] = []
  /// Path of the copy kept in each group, by group id.
  private(set) var kept: [String: String] = [:]
  /// Localized folder names ("Загрузки") by directory path.
  private(set) var folderNames: [String: String] = [:]
  /// Bumped by `invalidate()`; the screen restarts its task on change.
  private(set) var generation = 0
  var selectedID: String?
  var showsAllGroups = false

  @ObservationIgnored private var finder: DuplicateFinder?
  @ObservationIgnored private var progressTask: Task<Void, Never>?

  init(app: AppModel) {
    self.app = app
  }

  func invalidate() {
    stop()
    state = .idle
    progress = DuplicateProgress()
    groups = []
    kept = [:]
    folderNames = [:]
    selectedID = nil
    showsAllGroups = false
    generation += 1
  }

  // MARK: - Finding

  func startIfNeeded() {
    guard state == .idle, app.tree != nil else { return }
    start()
  }

  func start() {
    guard let tree = app.tree else { return }
    stop()
    let options = DuplicateFinder.Options(excludedPaths: app.settings.exclusions)
    let finder = DuplicateFinder(tree: tree, options: options)
    self.finder = finder
    state = .finding
    progress = DuplicateProgress()

    progressTask = Task { [weak self] in
      while !Task.isCancelled {
        self?.progress = finder.progress
        try? await Task.sleep(for: .milliseconds(80))
      }
    }

    Task { [weak self] in
      let result = await finder.find()
      let names = await Task.detached(priority: .utility) {
        Self.displayNames(for: result ?? [])
      }.value
      guard let self, self.finder === finder else { return }
      self.progressTask?.cancel()
      self.progress = finder.progress
      self.finder = nil
      guard let result else {
        self.state = .cancelled
        return
      }
      self.folderNames = names
      self.groups = result
      self.kept = Self.autoKeeps(result)
      self.selectedID = result.first?.id
      self.state = .ready
    }
  }

  func cancel() {
    guard state == .finding else { return }
    stop()
    state = .cancelled
  }

  private func stop() {
    finder?.cancel()
    finder = nil
    progressTask?.cancel()
    progressTask = nil
  }

  nonisolated private static func displayNames(for groups: [DuplicateGroup]) -> [String: String] {
    let fm = FileManager.default
    var names: [String: String] = [:]
    for group in groups {
      for file in group.files where names[file.directory] == nil {
        names[file.directory] = fm.displayName(atPath: file.directory)
      }
    }
    return names
  }

  private static func autoKeeps(_ groups: [DuplicateGroup]) -> [String: String] {
    var result: [String: String] = [:]
    for group in groups { result[group.id] = group.autoOriginal() }
    return result
  }

  // MARK: - Selection

  var selectedGroup: DuplicateGroup? {
    groups.first { $0.id == selectedID } ?? groups.first
  }

  var visibleGroups: ArraySlice<DuplicateGroup> {
    showsAllGroups ? groups[...] : groups.prefix(Self.initialLimit)
  }

  func keptPath(_ group: DuplicateGroup) -> String? {
    kept[group.id] ?? group.files.first?.path
  }

  func keep(_ file: DuplicateFile, in group: DuplicateGroup) {
    kept[group.id] = file.path
  }

  /// "Автовыбор оригиналов": the copy outside Downloads and Desktop, else
  /// the oldest, in every group.
  func autoSelect() {
    kept = Self.autoKeeps(groups)
  }

  func waste(_ group: DuplicateGroup) -> UInt64 {
    group.waste(keeping: keptPath(group))
  }

  var totalWaste: UInt64 { groups.reduce(0) { $0 + waste($1) } }

  /// Copies marked "Удалить" in every group.
  var copiesToDelete: [DuplicateFile] {
    groups.flatMap { group in
      let keep = keptPath(group)
      return group.files.filter { $0.path != keep }
    }
  }

  func folderName(_ file: DuplicateFile) -> String {
    folderNames[file.directory] ?? (file.directory as NSString).lastPathComponent
  }

  // MARK: - Removal

  func deleteCopies() {
    let items = copiesToDelete.map { DeletionItem(url: $0.url, size: $0.privateSize) }
    app.requestDeletion(
      DeletionRequest(
        items: items, source: .duplicates, recordTitle: String(localized: "Дубликаты"),
        onComplete: { [weak self] outcome in self?.applyRemoval(outcome) }))
  }

  private func applyRemoval(_ outcome: RemovalOutcome) {
    let removed = Set(outcome.removed.map(\.originalPath))
    guard !removed.isEmpty else { return }
    var updated: [DuplicateGroup] = []
    for var group in groups {
      group.files.removeAll { removed.contains($0.path) }
      guard group.files.count > 1 else {
        kept[group.id] = nil
        continue
      }
      if let keep = kept[group.id], !group.files.contains(where: { $0.path == keep }) {
        kept[group.id] = group.autoOriginal()
      }
      updated.append(group)
    }
    groups = updated
    if let selectedID, !updated.contains(where: { $0.id == selectedID }) {
      self.selectedID = updated.first?.id
    }
  }
}
