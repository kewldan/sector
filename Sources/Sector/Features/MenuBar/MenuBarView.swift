import SectorCore
import SwiftUI

/// Placeholder — implemented per design/mockups/MenuBar.dc.html.
struct MenuBarView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    EmptyStateView(symbol: "hammer", title: "Sector", message: "Скоро")
  }
}

/// Menu bar icon: ring of used space and free gigabytes.
struct MenuBarLabel: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Image(systemName: "chart.pie")
  }
}
