import SectorCore
import SwiftUI

/// Placeholder — implemented per design/mockups/Overview.dc.html.
struct OverviewView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    EmptyStateView(symbol: "hammer", title: "Обзор", message: "Скоро")
  }
}
