import SectorCore
import SwiftUI

/// Placeholder — implemented per design/mockups/Apps.dc.html.
struct AppsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    EmptyStateView(symbol: "hammer", title: "Приложения", message: "Скоро")
  }
}
