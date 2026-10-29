import SectorCore
import SwiftUI

/// Placeholder — implemented per design/mockups/Scan.dc.html.
struct ScanView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    EmptyStateView(symbol: "hammer", title: "Сканирование", message: "Скоро")
  }
}
