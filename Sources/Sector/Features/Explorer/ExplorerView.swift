import SectorCore
import SwiftUI

/// Placeholder — implemented per design/mockups/Explorer.dc.html.
struct ExplorerView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    EmptyStateView(symbol: "hammer", title: "Карта диска", message: "Скоро")
  }
}
