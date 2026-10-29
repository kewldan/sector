import SectorCore
import SwiftUI

/// Placeholder — implemented per design/mockups/ConfirmDelete.dc.html.
struct ConfirmDeleteSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let request: DeletionRequest

  var body: some View {
    VStack(spacing: 16) {
      Text("Переместить в Корзину?").font(.sectorSection)
      HStack {
        Button("Отменить") { dismiss() }
        Button("Переместить в Корзину") {
          Task {
            await model.perform(request, mode: .trash)
            dismiss()
          }
        }
        .buttonStyle(.glassProminent)
      }
    }
    .padding(28)
  }
}
