import SectorCore
import SwiftUI

/// Placeholder — implemented per design/mockups/Permission.dc.html.
struct PermissionView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    EmptyStateView(symbol: "hammer", title: "Нужен полный доступ к диску", message: "Скоро")
  }
}
