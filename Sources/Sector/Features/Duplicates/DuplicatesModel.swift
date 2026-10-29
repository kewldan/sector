import Foundation
import Observation
import SectorCore

/// Duplicate finder over the scanned tree.
///
/// Contract: `invalidate()` is called by `AppModel` after a new scan.
@Observable @MainActor
final class DuplicatesModel {
  @ObservationIgnored unowned let app: AppModel

  init(app: AppModel) {
    self.app = app
  }

  func invalidate() {}
}
