import Foundation
import Observation
import SectorCore

/// Installed applications with their related data.
///
/// Contract: `invalidate()` is called by `AppModel` after a new scan.
@Observable @MainActor
final class AppsModel {
  @ObservationIgnored unowned let app: AppModel

  init(app: AppModel) {
    self.app = app
  }

  func invalidate() {}
}
