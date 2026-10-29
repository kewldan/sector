import SectorCore
import SwiftUI

/// Placeholder — implemented per design/mockups/Settings.dc.html.
struct SettingsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    EmptyStateView(symbol: "hammer", title: "Настройки", message: "Скоро")
  }
}
