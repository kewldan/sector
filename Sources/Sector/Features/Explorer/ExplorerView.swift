import SectorCore
import SwiftUI

/// "Карта диска": breadcrumbs, a rings / tiles switch, the chart and the
/// inspector. Implements design/mockups/Explorer.dc.html.
struct ExplorerView: View {
  @Environment(AppModel.self) private var model
  private let explorer = ExplorerModel.shared

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.leading, 20)
        .padding(.trailing, 20)
        .frame(height: 52)
      HStack(spacing: 14) {
        chartCard
        ExplorerInspector(explorer: explorer)
          .appearAnimation(delay: 0.25)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 16)
    }
    .navigationTitle("Карта диска")
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button {
          explorer.goUp()
        } label: {
          Label("Назад", systemImage: "chevron.left")
        }
        .help("На уровень выше (⌘↑)")
        .keyboardShortcut(.upArrow, modifiers: .command)
        .disabled(!explorer.canGoUp)

        Button {
          explorer.goForward()
        } label: {
          Label("Вперёд", systemImage: "chevron.right")
        }
        .help("Вперёд (⌘])")
        .keyboardShortcut("]", modifiers: .command)
        .disabled(!explorer.canGoForward)
      }
    }
    .background { shortcuts }
    .task(id: model.treeVersion) {
      await explorer.sync(with: model)
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(spacing: 12) {
      ExplorerBreadcrumbs(explorer: explorer)
      Spacer(minLength: 12)
      ExplorerModePicker(
        mode: Binding(
          get: { explorer.mode },
          set: { mode in
            explorer.hover = nil
            explorer.mode = mode
          }))
    }
  }

  // MARK: - Chart

  private var chartCard: some View {
    ZStack(alignment: .bottomLeading) {
      Group {
        if let rings = explorer.rings, rings.segments.isEmpty, explorer.zoom == nil {
          EmptyStateView(
            symbol: "folder", title: "Папка пуста",
            message: "Здесь нет файлов, занимающих место на диске.")
        } else if explorer.rings == nil {
          ProgressView().controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if explorer.mode == .rings {
          SunburstChart(explorer: explorer)
            .id(explorer.entrance)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
          TreemapChart(explorer: explorer)
            .id(explorer.entrance)
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .animation(Motion.resolve(Motion.smooth), value: explorer.mode)

      // Tiles fill the whole card, so the hint would cover them.
      Text(hint)
        .opacity(explorer.mode == .tiles ? 0 : 1)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.leading, 16)
        .padding(.bottom, 14)
        .allowsHitTesting(false)
        .contentTransition(.opacity)
        .animation(Motion.resolve(Motion.quick), value: hint)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.sectorCard.opacity(0.75), in: .rect(cornerRadius: Metrics.cardRadius))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.cardRadius)
        .strokeBorder(Color.sectorHairline, lineWidth: 0.5)
    )
    .clipShape(.rect(cornerRadius: Metrics.cardRadius))
  }

  private var hint: LocalizedStringKey {
    if explorer.mode == .tiles { return "Наведите на плитку, чтобы увидеть детали" }
    return explorer.canGoUp
      ? "Нажмите в центр, чтобы вернуться" : "Нажмите на сегмент, чтобы приблизить"
  }

  /// Esc and ⌘[ go up a level as well.
  private var shortcuts: some View {
    ZStack {
      Button("") { explorer.goUp() }
        .keyboardShortcut(.escape, modifiers: [])
      Button("") { explorer.goUp() }
        .keyboardShortcut("[", modifiers: .command)
    }
    .opacity(0)
    .frame(width: 0, height: 0)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Clickable path from the disk to the focus folder.
private struct ExplorerBreadcrumbs: View {
  let explorer: ExplorerModel

  /// Long paths keep the first two and last three crumbs.
  private var visible: (head: [ExplorerCrumb], hidden: [ExplorerCrumb], tail: [ExplorerCrumb]) {
    let crumbs = explorer.crumbs
    guard crumbs.count > 6 else { return (crumbs, [], []) }
    return (
      Array(crumbs.prefix(2)), Array(crumbs.dropFirst(2).dropLast(3)), Array(crumbs.suffix(3))
    )
  }

  var body: some View {
    let parts = visible
    let lastID = explorer.crumbs.last?.id
    HStack(spacing: 4) {
      ForEach(Array(parts.head.enumerated()), id: \.element.id) { index, crumb in
        if index > 0 { separator }
        crumbView(crumb, isLast: crumb.id == lastID)
      }
      if !parts.hidden.isEmpty {
        separator
        Menu {
          ForEach(parts.hidden) { crumb in
            if let node = crumb.node {
              Button(crumb.name) { explorer.zoom(to: node) }
            }
          }
        } label: {
          Text("…")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Color.sectorAccent)
      }
      ForEach(parts.tail) { crumb in
        separator
        crumbView(crumb, isLast: crumb.id == lastID)
      }
    }
    .font(.system(size: 13))
    .lineLimit(1)
    .animation(Motion.resolve(Motion.smooth), value: explorer.crumbs)
  }

  private var separator: some View {
    Text("›").foregroundStyle(.tertiary).accessibilityHidden(true)
  }

  @ViewBuilder
  private func crumbView(_ crumb: ExplorerCrumb, isLast: Bool) -> some View {
    if isLast {
      Text(crumb.name)
        .fontWeight(.semibold)
        .foregroundStyle(.primary)
        .truncationMode(.middle)
        .transition(.opacity.combined(with: .offset(y: 6)))
    } else if let node = crumb.node {
      Button(crumb.name) { explorer.zoom(to: node) }
        .buttonStyle(.plain)
        .fontWeight(.medium)
        .foregroundStyle(Color.sectorAccent)
        .truncationMode(.middle)
    } else {
      Text(crumb.name).foregroundStyle(.secondary)
    }
  }
}

/// "Кольца / Плитки" with a pill that slides between the options.
private struct ExplorerModePicker: View {
  @Binding var mode: ExplorerModel.Mode
  @Namespace private var namespace

  var body: some View {
    HStack(spacing: 0) {
      option(.rings, title: "Кольца", symbol: "circle.circle")
      option(.tiles, title: "Плитки", symbol: "square.split.2x2")
    }
    .padding(2)
    .background(Color.sectorTrack, in: .capsule)
    .animation(Motion.resolve(Motion.bouncy), value: mode)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Вид")
  }

  private func option(
    _ value: ExplorerModel.Mode, title: LocalizedStringKey, symbol: String
  ) -> some View {
    let selected = mode == value
    return Button {
      if !selected { mode = value }
    } label: {
      Label(title, systemImage: symbol)
        .font(.system(size: 12, weight: .semibold))
        .labelStyle(.titleAndIcon)
        .frame(width: 88, height: 28)
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .background {
          if selected {
            Capsule()
              .fill(.background)
              .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
              .overlay(Capsule().strokeBorder(Color.sectorHairline, lineWidth: 0.5))
              .matchedGeometryEffect(id: "pill", in: namespace)
          }
        }
        .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
