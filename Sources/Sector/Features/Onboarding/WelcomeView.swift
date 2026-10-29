import SectorCore
import SwiftUI

/// Placeholder — implemented per design/mockups/Main.dc.html.
struct WelcomeView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    EmptyStateView(symbol: "hammer", title: "Добро пожаловать в Sector", message: "Скоро")
  }
}
