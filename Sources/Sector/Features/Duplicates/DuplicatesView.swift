import SectorCore
import SwiftUI

/// Placeholder — implemented per design/mockups/Duplicates.dc.html.
struct DuplicatesView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    EmptyStateView(symbol: "hammer", title: "Дубликаты", message: "Скоро")
  }
}
