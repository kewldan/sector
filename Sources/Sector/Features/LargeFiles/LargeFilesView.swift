import AppKit
import SectorCore
import SwiftUI

/// Files of 1 GB and more, per design/mockups/LargeFiles.dc.html.
struct LargeFilesView: View {
  @Environment(AppModel.self) private var model

  /// nil while the first lookup runs.
  @State private var files: [LargeFile]?
  @State private var opened: [String: Date] = [:]
  @State private var filter: LargeFilesFilter = .all
  @State private var sort: LargeFilesSort = .size
  @State private var ascending = false
  @State private var search = ""
  @State private var selection: Set<String> = []
  @State private var anchor: String?
  /// Rows that appear before this moment play the staggered entrance.
  @State private var animateRowsUntil = Date.distantPast
  @FocusState private var listFocused: Bool
  @Namespace private var filterSpace

  private var gigabyte: UInt64 { UInt64(ByteFormat.base * ByteFormat.base * ByteFormat.base) }

  var body: some View {
    let rows = visibleRows
    VStack(alignment: .leading, spacing: 14) {
      header(rows)
      content(rows)
        .appearAnimation(delay: 0.1)
    }
    .padding(.horizontal, Metrics.pagePadding)
    .padding(.top, 20)
    .padding(.bottom, 20)
    .overlay(alignment: .bottom) { selectionBar }
    .animation(Motion.resolve(Motion.bouncy), value: selection.isEmpty)
    .task(id: model.treeVersion) { await reload() }
    .onChange(of: filter) { restartRowAnimation() }
    .onChange(of: selection) { QuickLookPreview.shared.updateIfVisible(selectedURLs) }
  }

  // MARK: - Header

  private func header(_ rows: [LargeFile]) -> some View {
    PageHeader("Большие и старые файлы", subtitle: subtitle(rows)) {
      HStack(spacing: 12) {
        filterChips
        searchField
      }
    }
  }

  private func subtitle(_ rows: [LargeFile]) -> String {
    let limit = String(localized: "Больше 1 ГБ")
    guard files != nil else { return limit }
    let total = rows.reduce(UInt64(0)) { $0 + $1.size }
    let count = Plural.format(rows.count, "файл", "файла", "файлов")
    return "\(limit) · \(count), \(ByteFormat.string(total))"
  }

  private var filterChips: some View {
    HStack(spacing: 0) {
      ForEach(LargeFilesFilter.allCases, id: \.self) { item in
        Button {
          withAnimation(Motion.resolve(Motion.bouncy)) { filter = item }
        } label: {
          Text(item.title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(filter == item ? Color.primary : Color.secondary)
            .frame(width: 110, height: 28)
            .background {
              if filter == item {
                Capsule()
                  .fill(Color.chipSelected)
                  .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                  .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                  .matchedGeometryEffect(id: "pill", in: filterSpace)
              }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == item ? [.isSelected] : [])
      }
    }
    .padding(2)
    .background(Color.primary.opacity(0.06), in: .capsule)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Фильтр"))
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
      TextField("Имя файла", text: $search)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .onSubmit { listFocused = true }
      if !search.isEmpty {
        Button {
          search = ""
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Очистить поиск"))
      }
    }
    .padding(.horizontal, 12)
    .frame(width: 180, height: 32)
    .background(Color.sectorCard, in: .capsule)
    .overlay(Capsule().strokeBorder(Color.sectorHairline, lineWidth: 0.5))
    .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
  }

  // MARK: - List

  @ViewBuilder private func content(_ rows: [LargeFile]) -> some View {
    VStack(spacing: 0) {
      columnHeader
      Rectangle().fill(Color.sectorHairline).frame(height: 0.5)
      if files == nil {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if files?.isEmpty == true {
        EmptyStateView(
          symbol: "checkmark.circle", title: "Больших файлов нет",
          message: "На диске не нашлось файлов больше 1 ГБ.")
      } else if rows.isEmpty {
        filteredEmptyState
      } else {
        list(rows)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.sectorCard, in: .rect(cornerRadius: Metrics.cardRadius))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.cardRadius)
        .strokeBorder(Color.sectorHairline, lineWidth: 0.5)
    )
    .clipShape(.rect(cornerRadius: Metrics.cardRadius))
    .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
  }

  @ViewBuilder private var filteredEmptyState: some View {
    if !search.isEmpty {
      EmptyStateView(
        symbol: "magnifyingglass", title: "Ничего не найдено",
        message: "Нет больших файлов с таким именем.")
    } else if filter == .old {
      EmptyStateView(
        symbol: "clock", title: "Старых файлов нет",
        message: "Все большие файлы открывались за последние полгода.")
    } else {
      EmptyStateView(
        symbol: "doc", title: "Файлов больше 20 ГБ нет",
        message: "Самые крупные файлы — в фильтре «Все».")
    }
  }

  private var columnHeader: some View {
    HStack(spacing: 12) {
      Color.clear.frame(width: 20, height: 1)
      sortButton("Имя", key: .name)
        .padding(.leading, 46)
        .frame(maxWidth: .infinity, alignment: .leading)
      sortButton("Открывался", key: .opened)
        .frame(width: 130, alignment: .leading)
      sortButton("Размер", key: .size)
        .frame(width: 170, alignment: .trailing)
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 18)
    .frame(height: 36)
  }

  private func sortButton(_ title: LocalizedStringKey, key: LargeFilesSort) -> some View {
    Button {
      withAnimation(Motion.resolve(Motion.smooth)) {
        if sort == key {
          ascending.toggle()
        } else {
          sort = key
          ascending = key.defaultAscending
        }
      }
    } label: {
      HStack(spacing: 3) {
        Text(title)
        if sort == key {
          Image(systemName: ascending ? "arrow.up" : "arrow.down")
            .font(.system(size: 9, weight: .bold))
            .transition(.opacity.combined(with: .scale))
        }
      }
      .foregroundStyle(sort == key ? Color.primary.opacity(0.75) : Color.secondary)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }

  private func list(_ rows: [LargeFile]) -> some View {
    let maxSize = rows.map(\.size).max() ?? 1
    let animateUntil = animateRowsUntil
    return ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, file in
          LargeFileRow(
            file: file,
            opened: opened[file.path] ?? file.modified,
            fraction: Double(file.size) / Double(max(maxSize, 1)),
            isSelected: selection.contains(file.path),
            entranceDelay: Date() < animateUntil ? Motion.stagger(index, step: 0.045) : nil,
            onToggle: { toggle(file) },
            onTap: { tap(file, in: rows) }
          )
          .contextMenu { contextMenu(for: file) }
          .transition(
            .asymmetric(
              insertion: .opacity,
              removal: .opacity.combined(with: .move(edge: .leading))))
        }
      }
      .id(filter)
      .padding(.horizontal, 8)
      .padding(.top, 6)
      .padding(.bottom, 80)
    }
    .focusable(interactions: .edit)
    .focusEffectDisabled()
    .focused($listFocused)
    .onKeyPress(.space) {
      previewSelection()
      return .handled
    }
    .onKeyPress(.escape) {
      guard !selection.isEmpty else { return .ignored }
      clearSelection()
      return .handled
    }
    .onKeyPress(characters: CharacterSet(charactersIn: "aA"), phases: .down) { press in
      guard press.modifiers.contains(.command) else { return .ignored }
      selectAll(rows)
      return .handled
    }
    .onCommand(#selector(NSResponder.selectAll(_:))) { selectAll(rows) }
  }

  @ViewBuilder private func contextMenu(for file: LargeFile) -> some View {
    Button("Показать в Finder") { model.revealInFinder([file.url]) }
    Button("Просмотр") { QuickLookPreview.shared.show([file.url]) }
    Divider()
    Button("Удалить…", role: .destructive) {
      let targets = selection.contains(file.path) ? selectedFiles : [file]
      requestDeletion(targets)
    }
  }

  // MARK: - Selection bar

  @ViewBuilder private var selectionBar: some View {
    if !selection.isEmpty {
      let chosen = selectedFiles
      let size = chosen.reduce(UInt64(0)) { $0 + $1.size }
      HStack(spacing: 10) {
        Text("Выбрано").foregroundStyle(.secondary)
        Text(
          verbatim:
            "\(Plural.format(chosen.count, "файл", "файла", "файлов")) · \(ByteFormat.string(size))"
        )
        .fontWeight(.bold)
        .monospacedDigit()
        .contentTransition(.numericText())
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5, height: 22)
          .padding(.horizontal, 4)
        Button("Снять выбор", action: clearSelection)
          .buttonStyle(.borderless)
          .foregroundStyle(.primary)
          .padding(.horizontal, 8)
        Button(action: previewSelection) {
          Label("Просмотр", systemImage: "eye")
        }
        .buttonStyle(.glass)
        Button {
          requestDeletion(chosen)
        } label: {
          Label("Удалить…", systemImage: "trash")
        }
        .buttonStyle(.glassProminent)
        .tint(.sectorDanger)
      }
      .font(.system(size: 13))
      .controlSize(.large)
      .fixedSize()
      .padding(.leading, 18)
      .padding(.trailing, 8)
      .frame(height: 52)
      .glassEffect(.regular, in: .capsule)
      .shadow(color: Color(hex: 0x141E46).opacity(0.22), radius: 20, y: 18)
      .padding(.bottom, 30)
      .transition(
        .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
    }
  }

  // MARK: - Data

  private var visibleRows: [LargeFile] {
    guard let files else { return [] }
    let now = Date()
    let halfYear = now.addingTimeInterval(-182 * 86_400)
    let big = gigabyte * 20
    let query = search.trimmingCharacters(in: .whitespaces)
    var rows = files.filter { file in
      switch filter {
      case .all: break
      case .old: if (opened[file.path] ?? file.modified) >= halfYear { return false }
      case .big: if file.size < big { return false }
      }
      return query.isEmpty || file.name.localizedStandardContains(query)
    }
    rows.sort { a, b in
      let ordered: Bool
      switch sort {
      case .name:
        let r = a.name.localizedStandardCompare(b.name)
        if r == .orderedSame { return a.path < b.path }
        ordered = r == .orderedAscending
      case .opened:
        let da = opened[a.path] ?? a.modified
        let db = opened[b.path] ?? b.modified
        if da == db { return a.size > b.size }
        ordered = da < db
      case .size:
        if a.size == b.size { return a.path < b.path }
        ordered = a.size < b.size
      }
      return ascending ? ordered : !ordered
    }
    return rows
  }

  private var selectedFiles: [LargeFile] {
    (files ?? []).filter { selection.contains($0.path) }.sorted { $0.size > $1.size }
  }

  private var selectedURLs: [URL] { selectedFiles.map(\.url) }

  private func reload() async {
    guard let tree = model.tree else {
      files = []
      return
    }
    let minSize = gigabyte
    let home = NSHomeDirectory()
    let found = await Task.detached(priority: .userInitiated) {
      LargeFilesScan.collect(tree, minSize: minSize, home: home)
    }.value
    guard !Task.isCancelled else { return }
    let settings = model.settings
    let visible = found.filter { !settings.isExcluded($0.path) }
    let isFirstLoad = files == nil
    if isFirstLoad { restartRowAnimation() }
    withAnimation(isFirstLoad ? nil : Motion.resolve(Motion.smooth)) {
      files = visible
      selection.formIntersection(visible.map(\.path))
    }

    let missing = visible.filter { opened[$0.path] == nil }
    guard !missing.isEmpty else { return }
    let dates = await Task.detached(priority: .utility) {
      LargeFilesScan.openedDates(missing)
    }.value
    guard !Task.isCancelled else { return }
    withAnimation(Motion.resolve(Motion.quick)) {
      opened.merge(dates) { _, new in new }
    }
  }

  private func restartRowAnimation() {
    animateRowsUntil = Date().addingTimeInterval(1)
  }

  // MARK: - Actions

  private func toggle(_ file: LargeFile) {
    listFocused = true
    withAnimation(Motion.resolve(Motion.quick)) {
      if selection.contains(file.path) {
        selection.remove(file.path)
      } else {
        selection.insert(file.path)
      }
    }
    anchor = file.path
  }

  /// Finder-style clicks: plain selects one, ⌘ toggles, ⇧ extends a range.
  private func tap(_ file: LargeFile, in rows: [LargeFile]) {
    listFocused = true
    let flags = NSEvent.modifierFlags
    if flags.contains(.shift), let anchor,
      let from = rows.firstIndex(where: { $0.path == anchor }),
      let to = rows.firstIndex(of: file)
    {
      withAnimation(Motion.resolve(Motion.quick)) {
        selection.formUnion(rows[min(from, to)...max(from, to)].map(\.path))
      }
      return
    }
    if flags.contains(.command) {
      toggle(file)
      return
    }
    withAnimation(Motion.resolve(Motion.quick)) {
      selection = selection == [file.path] ? [] : [file.path]
    }
    anchor = file.path
  }

  private func selectAll(_ rows: [LargeFile]) {
    withAnimation(Motion.resolve(Motion.quick)) {
      selection.formUnion(rows.map(\.path))
    }
  }

  private func clearSelection() {
    withAnimation(Motion.resolve(Motion.quick)) { selection.removeAll() }
    anchor = nil
  }

  private func previewSelection() {
    QuickLookPreview.shared.toggle(selectedURLs)
  }

  private func requestDeletion(_ targets: [LargeFile]) {
    guard !targets.isEmpty else { return }
    model.requestDeletion(
      DeletionRequest(
        items: targets.map { DeletionItem(url: $0.url, size: $0.size) },
        source: .files,
        recordTitle: String(localized: "Большие и старые файлы")))
  }
}

// MARK: - Row

private struct LargeFileRow: View {
  let file: LargeFile
  let opened: Date
  let fraction: Double
  let isSelected: Bool
  /// Delay of the staggered entrance, or nil to show at once.
  let entranceDelay: Double?
  let onToggle: () -> Void
  let onTap: () -> Void

  @State private var hovered = false
  @State private var appeared = false

  var body: some View {
    let color = file.kindColor
    HStack(spacing: 12) {
      Button(action: onToggle) {
        SelectionCheck(isOn: isSelected)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("Выбрать \(file.name)"))

      FileKindBadge(label: file.kindLabel, color: color, size: 34)

      VStack(alignment: .leading, spacing: 1) {
        Text(file.name)
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
          .truncationMode(.middle)
        Text(file.folder)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .help(file.path)

      Text(OpenedFormat.string(opened))
        .font(.system(size: 12))
        .foregroundStyle(ageColor)
        .lineLimit(1)
        .frame(width: 130, alignment: .leading)

      HStack(spacing: 10) {
        Capsule()
          .fill(Color.sectorTrack)
          .frame(width: 80, height: 5)
          .overlay(alignment: .leading) {
            Capsule()
              .fill(color)
              .frame(width: max(3, 80 * fraction))
              .scaleEffect(x: appeared ? 1 : 0, anchor: .leading)
          }
        Text(ByteFormat.string(file.size))
          .font(.system(size: 13, weight: .semibold))
          .monospacedDigit()
          .lineLimit(1)
          .frame(width: 66, alignment: .trailing)
      }
      .frame(width: 170, alignment: .trailing)
    }
    .padding(.horizontal, 10)
    .frame(height: 54)
    .background(background, in: .rect(cornerRadius: 12))
    .contentShape(.rect(cornerRadius: 12))
    .onHover { h in
      withAnimation(Motion.resolve(Motion.quick)) { hovered = h }
    }
    .onTapGesture(perform: onTap)
    .opacity(appeared ? 1 : 0)
    .offset(x: appeared || Motion.reduced ? 0 : -14)
    .onAppear {
      guard !appeared else { return }
      if let entranceDelay, !Motion.reduced {
        withAnimation(Motion.smooth.delay(entranceDelay)) { appeared = true }
      } else {
        appeared = true
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private var background: Color {
    if isSelected { return Color.sectorAccent.opacity(0.09) }
    return hovered ? Color.sectorAccent.opacity(0.05) : Color.clear
  }

  private var ageColor: Color {
    let months = OpenedFormat.months(since: opened)
    if months >= 12 { return .sectorWarning }
    if months >= 6 { return Color.primary.opacity(0.8) }
    return .secondary
  }
}

extension Color {
  /// Selected segment of the filter chips.
  fileprivate static let chipSelected = Color(light: 0xFFFFFF, dark: 0x636366)
}
