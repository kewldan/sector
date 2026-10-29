import SectorCore
import SwiftUI

/// "Крупнейшие папки": the folders worth knowing about, each opening the
/// disk map on itself.
struct LargestFoldersCard: View {
  @Environment(AppModel.self) private var model
  var folders: [OverviewSnapshot.Folder]?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Крупнейшие папки")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        Button("Открыть карту ›") { open(nil) }
          .buttonStyle(.plain)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color.sectorAccent)
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 6)

      if let folders {
        if folders.isEmpty {
          Text("Папок, занимающих заметное место, не нашлось.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(8)
        } else {
          let largest = folders.first?.size ?? 1
          ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
            FolderRow(
              folder: folder, fraction: Double(folder.size) / Double(max(1, largest)),
              color: color(folder.id), index: index
            ) {
              open(folder.path)
            }
            .appearAnimation(delay: 0.5 + Double(index) * 0.07)
          }
        }
      } else {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, minHeight: 120)
      }
    }
    .padding(.top, 14)
    .padding(.horizontal, 12)
    .padding(.bottom, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .overviewCard()
  }

  private func color(_ node: NodeID) -> Color {
    ExplorerPalette(breakdown: model.breakdown).base(node)
  }

  private func open(_ path: String?) {
    ExplorerModel.shared.open(path: path)
    model.route = .explorer
  }
}

private struct FolderRow: View {
  var folder: OverviewSnapshot.Folder
  var fraction: Double
  var color: Color
  var index: Int
  var action: () -> Void
  @State private var hovered = false
  @State private var grown = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        IconBadge(symbol: "folder", color: color, size: 28)
        VStack(alignment: .leading, spacing: 1) {
          Text(folder.name)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
          Text(folder.location)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
        }
        .frame(width: 190, alignment: .leading)
        GeometryReader { geo in
          Capsule().fill(Color.primary.opacity(0.06))
            .overlay(alignment: .leading) {
              Capsule().fill(color)
                .frame(width: max(3, geo.size.width * fraction))
                .scaleEffect(x: grown ? 1 : 0, anchor: .leading)
            }
        }
        .frame(height: 6)
        Text(ByteFormat.string(folder.size))
          .font(.system(size: 13, weight: .semibold))
          .monospacedDigit()
          .frame(width: 70, alignment: .trailing)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(Color.sectorAccent.opacity(hovered ? 0.07 : 0), in: .rect(cornerRadius: 10))
      .contentShape(.rect(cornerRadius: 10))
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .animation(Motion.resolve(Motion.quick), value: hovered)
    .help(folder.path)
    .onAppear {
      withAnimation(
        Motion.resolve(.spring(duration: 1, bounce: 0))
          .delay(Motion.reduced ? 0 : 0.65 + Double(index) * 0.08)
      ) { grown = true }
    }
    .accessibilityLabel(Text("\(folder.name), \(ByteFormat.string(folder.size))"))
    .accessibilityHint("Открыть на карте диска")
  }
}

/// "Быстрые действия": Trash, old downloads and Xcode caches.
struct QuickActionsCard: View {
  @Environment(AppModel.self) private var model
  var snapshot: OverviewSnapshot?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Быстрые действия")
        .font(.system(size: 13, weight: .semibold))
        .padding(.leading, 4)
        .padding(.bottom, 4)

      let trashCount = snapshot?.trash.count ?? 0
      let trashItems = Plural.format(trashCount, "объект", "объекта", "объектов")
      ActionRow(
        symbol: "trash", color: DiskCategory.trash.color, title: "Корзина",
        detail: snapshot?.trashDenied == true
          ? String(localized: "Нет доступа")
          : trashCount == 0
          ? String(localized: "Пусто")
          : "\(ByteFormat.string(snapshot?.trashSize ?? 0)) · \(trashItems)",
        button: "trash.empty", isEnabled: trashCount > 0
      ) {
        guard let snapshot, !snapshot.trash.isEmpty else { return }
        model.requestDeletion(
          DeletionRequest(
            items: snapshot.trash, source: .trash, recordTitle: String(localized: "Корзина")))
      }

      let days = model.settings.minimumAgeDays
      let age = String(localized: "старше \(Plural.format(days, "дня", "дней", "дней"))")
      ActionRow(
        symbol: "arrow.down.to.line", color: Color(hex: 0x30B0C7), title: "Старые загрузки",
        detail: snapshot?.downloadsDenied == true
          ? String(localized: "Нет доступа")
          : (snapshot?.oldDownloadsSize ?? 0) > 0
          ? "\(ByteFormat.string(snapshot?.oldDownloadsSize ?? 0)) · \(age)"
          : String(localized: "Нет файлов \(age)"),
        button: "Проверить", isEnabled: true
      ) {
        model.route = .largeFiles
      }

      if let size = snapshot?.xcodeCachesSize, size > 0 {
        ActionRow(
          symbol: "chevron.left.forwardslash.chevron.right", color: Color(hex: 0x5E5CE6),
          title: "Кэши Xcode",
          detail: String(localized: "\(ByteFormat.string(size)) · пересоберутся сами"),
          button: "Очистить", isEnabled: true
        ) {
          model.route = .smartClean
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.top, 14)
    .padding(.horizontal, 14)
    .padding(.bottom, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .overviewCard()
  }
}

private struct ActionRow: View {
  var symbol: String
  var color: Color
  var title: LocalizedStringKey
  var detail: String
  var button: LocalizedStringKey
  var isEnabled: Bool
  var action: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      IconBadge(symbol: symbol, color: color, size: 32)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 13, weight: .medium))
        Text(detail)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .lineLimit(1)
          .contentTransition(.numericText())
      }
      Spacer(minLength: 8)
      Button(button, action: action)
        .buttonStyle(.glass)
        .controlSize(.small)
        .font(.system(size: 12, weight: .semibold))
        .disabled(!isEnabled)
    }
    .padding(8)
    .background(Color.primary.opacity(0.03), in: .rect(cornerRadius: 14))
  }
}
