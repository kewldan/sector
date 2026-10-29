import Foundation
import Observation
import SectorCore
import WidgetKit

/// Keeps the desktop widgets' snapshot current: whenever free space or the
/// Smart Clean results change, writes `WidgetSnapshot` to the App Group
/// container and asks WidgetKit to reload.
@MainActor
final class WidgetBridge {
  private let model: AppModel
  private var pending: Task<Void, Never>?
  private var last: WidgetSnapshot?

  init(model: AppModel) {
    self.model = model
  }

  func start() {
    guard WidgetSnapshot.fileURL != nil else { return }
    observe()
  }

  /// Re-arms itself after every change, the usual pattern for observing an
  /// `@Observable` model outside SwiftUI.
  private func observe() {
    withObservationTracking {
      _ = model.volume
      _ = model.smartClean.categories
      _ = model.smartClean.reclaimableBytes
    } onChange: { [weak self] in
      Task { @MainActor in
        self?.scheduleWrite()
        self?.observe()
      }
    }
    scheduleWrite()
  }

  private func scheduleWrite() {
    pending?.cancel()
    pending = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      self?.write()
    }
  }

  private func write() {
    guard let volume = model.volume else { return }
    let categories = model.smartClean.categories
      .map { WidgetSnapshot.Category(kind: $0.kind.rawValue, title: $0.shortTitle, bytes: $0.size) }
      .filter { $0.bytes > 0 }
      .sorted { $0.bytes > $1.bytes }
    var snapshot = WidgetSnapshot(
      volumeName: volume.name, total: volume.total, available: volume.available,
      reclaimable: model.smartClean.reclaimableBytes, categories: Array(categories.prefix(7)))
    // Only the content matters for deciding whether to reload.
    if var previous = last {
      previous.date = snapshot.date
      if previous == snapshot { return }
    }
    snapshot.date = Date()
    guard snapshot.save() else { return }
    last = snapshot
    WidgetCenter.shared.reloadAllTimelines()
  }
}
