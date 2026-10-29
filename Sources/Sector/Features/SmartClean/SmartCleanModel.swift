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
  @ObservationIgnored unowned let app: AppModel

  private(set) var reclaimableBytes: UInt64 = 0
  private(set) var isAnalyzing = false

  init(app: AppModel) {
    self.app = app
  }

  func invalidate() {
    Task { await analyze() }
  }

  func analyze() async {}

  func startCleaning() {}
}
