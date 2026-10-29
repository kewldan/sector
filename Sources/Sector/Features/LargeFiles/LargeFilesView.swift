import SectorCore
import SwiftUI

/// Placeholder — implemented per design/mockups/LargeFiles.dc.html.
struct LargeFilesView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    EmptyStateView(symbol: "hammer", title: "Большие и старые файлы", message: "Скоро")
  }
}
