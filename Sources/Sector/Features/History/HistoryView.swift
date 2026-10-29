import SectorCore
import SwiftUI

/// Placeholder — implemented per design/mockups/History.dc.html.
struct HistoryView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    EmptyStateView(symbol: "hammer", title: "История", message: "Скоро")
  }
}
