import AppKit
import SectorCore
import SwiftUI

/// Everything Sector removed, per design/mockups/History.dc.html.
struct HistoryView: View {
  @Environment(AppModel.self) private var model

  @State private var records: [CleanupRecord] = []
  /// nil until the off-main check of the Trash finishes.
  @State private var status: HistoryStatus?
  @State private var trash: TrashSnapshot?
  @State private var confirmsEmptyTrash = false
  @State private var isEmptyingTrash = false
  /// Bumped for changes `AppModel.historyVersion` does not see (undo).
  @State private var localVersion = 0

  private struct ReloadKey: Hashable {
    var history: Int
    var local: Int
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      PageHeader(
        "История", subtitle: String(localized: "Всё, что удалял Sector, и что ещё можно вернуть")
      ) {
        exportMenu
      }
      RatioHStack(ratios: [1.6, 1], spacing: 14) {
        FreedChart(months: HistoryFormat.months(records))
          .appearAnimation(delay: 0.1)
        TrashCard(
          snapshot: trash, restorableBytes: status?.restorableBytes ?? 0,
          keepDays: model.settings.keepDays, isEmptying: isEmptyingTrash,
          openSettings: openFullDiskAccess
        ) {
          confirmsEmptyTrash = true
        }
        .appearAnimation(delay: 0.18)
      }
      journal
    }
    .padding(.horizontal, Metrics.pagePadding)
    .padding(.top, 20)
    .padding(.bottom, 20)
    .task(id: ReloadKey(history: model.historyVersion, local: localVersion)) { await reload() }
    .confirmationDialog(
      "Очистить Корзину?", isPresented: $confirmsEmptyTrash, titleVisibility: .visible
    ) {
      Button("Очистить Корзину", role: .destructive) { emptyTrash() }
      Button("Отменить", role: .cancel) {}
    } message: {
      Text(emptyTrashMessage)
    }
  }

  // MARK: - Header

  private var exportMenu: some View {
    Menu {
      Button("Таблица CSV…") { export(.csv) }
      Button("Markdown…") { export(.markdown) }
    } label: {
      Label("Экспорт отчёта", systemImage: "arrow.down.to.line")
    }
    .menuStyle(.button)
    .buttonStyle(.glass)
    .fixedSize()
    .disabled(records.isEmpty)
  }

  private func export(_ format: HistoryReport.Format) {
    let snapshot = records
    Task {
      if let url = await HistoryReport.export(snapshot, format: format) {
        model.toast = Toast(text: String(localized: "Отчёт сохранён: \(url.lastPathComponent)"))
      }
    }
  }

  // MARK: - Journal

  @ViewBuilder private var journal: some View {
    let container = RoundedRectangle(cornerRadius: Metrics.cardRadius)
    Group {
      if records.isEmpty {
        EmptyStateView(
          symbol: "clock.arrow.circlepath", title: "История пуста",
          message:
            "Здесь появится всё, что Sector удалит или переместит в Корзину, — и что можно вернуть."
        )
      } else {
        ScrollView {
          LazyVStack(spacing: 6) {
            ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
              HistoryRow(
                record: record,
                state: rowState(record),
                isNew: index == 0 && isFresh(record),
                onRestore: { restore(record) }
              )
              .appearAnimation(delay: index < 10 ? Motion.stagger(index, step: 0.08, base: 0.3) : 0)
            }
          }
          .padding(.leading, 40)
          .padding(.trailing, 14)
          .padding(.vertical, 12)
          .background(alignment: .leading) { TimelineLine() }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.sectorCard.opacity(0.7), in: container)
    .overlay(container.strokeBorder(Color.sectorHairline, lineWidth: 0.5))
    .clipShape(container)
    .appearAnimation(delay: 0.24)
  }

  private func isFresh(_ record: CleanupRecord) -> Bool {
    !record.isFullyRestored && Date().timeIntervalSince(record.date) < 3600
  }

  private func rowState(_ record: CleanupRecord) -> HistoryRow.RowState {
    if record.mode == .permanent { return .gone(String(localized: "Удалено безвозвратно")) }
    if record.isFullyRestored { return .restored }
    guard let status else { return .checking }
    if status.restorable.contains(record.id) { return .restorable }
    if !record.restoredPaths.isEmpty { return .gone(String(localized: "Частично восстановлено")) }
    return .gone(String(localized: "Корзина очищена"))
  }

  // MARK: - Loading

  private func reload() async {
    let current = model.history.records
    withAnimation(Motion.resolve(Motion.smooth)) { records = current }
    let computed = await Task.detached(priority: .userInitiated) {
      (HistoryStatus.compute(current), TrashSnapshot.measure())
    }.value
    guard !Task.isCancelled else { return }
    withAnimation(Motion.resolve(Motion.smooth)) {
      status = computed.0
      trash = computed.1
    }
  }

  // MARK: - Restore

  private func restore(_ record: CleanupRecord) {
    let before = record.restoredPaths
    let count = model.restore(record)
    guard count > 0 else {
      model.toast = Toast(
        text: String(localized: "Не удалось восстановить: файлов уже нет в Корзине"))
      localVersion += 1
      return
    }
    let updated = model.history.records.first { $0.id == record.id } ?? record
    let returned = updated.restoredPaths.subtracting(before)
    let bytes = record.items.reduce(UInt64(0)) {
      returned.contains($1.originalPath) ? $0 + $1.size : $0
    }
    let model = model
    let bump = { localVersion += 1 }
    model.toast = Toast(
      text: String(localized: "Возвращено в исходные папки: \(ByteFormat.string(bytes))"),
      undo: {
        Task {
          await Self.undoRestore(model: model, recordID: record.id, paths: returned)
          bump()
        }
      })
  }

  /// Puts restored items back into the Trash and reopens the record.
  private static func undoRestore(model: AppModel, recordID: UUID, paths: Set<String>) async {
    guard var record = model.history.records.first(where: { $0.id == recordID }) else { return }
    let items = record.items
      .filter { paths.contains($0.originalPath) }
      .map { RemovalItem(url: URL(fileURLWithPath: $0.originalPath), size: $0.size) }
    let outcome = await FileRemover.remove(items, mode: .trash)
    guard !outcome.removed.isEmpty else { return }
    for removed in outcome.removed {
      if let i = record.items.firstIndex(where: { $0.originalPath == removed.originalPath }) {
        record.items[i].trashedPath = removed.trashedPath
      }
      record.restoredPaths.remove(removed.originalPath)
    }
    model.history.update(record)
    model.refreshVolume()
  }

  // MARK: - Trash

  private var emptyTrashMessage: String {
    guard let trash else { return "" }
    let count = Plural.format(trash.visibleCount, "объект", "объекта", "объектов")
    return String(
      localized:
        "\(count) (\(ByteFormat.string(trash.size))) будут удалены навсегда. Вернуть их будет нельзя."
    )
  }

  private func emptyTrash() {
    guard let snapshot = trash, !snapshot.items.isEmpty, !isEmptyingTrash else { return }
    isEmptyingTrash = true
    Task {
      let outcome = await FileRemover.remove(snapshot.items, mode: .permanent)
      model.applyRemoval(outcome)
      if !outcome.removed.isEmpty {
        let visible = outcome.removed.filter {
          ($0.originalPath as NSString).lastPathComponent != ".DS_Store"
        }
        model.recordCleanup(
          CleanupRecord(
            source: .trash, title: String(localized: "Очистка Корзины"),
            detail: Plural.format(visible.count, "объект", "объекта", "объектов"),
            mode: .permanent, items: visible))
        model.toast = Toast(
          text: String(
            localized: "Корзина очищена · освобождено \(ByteFormat.string(outcome.freedBytes))"))
      }
      if !outcome.failed.isEmpty {
        model.toast = Toast(
          text: String(
            localized:
              "Не удалось удалить: \(Plural.format(outcome.failed.count, "объект", "объекта", "объектов"))"
          ))
      }
      isEmptyingTrash = false
      localVersion += 1
    }
  }

  private func openFullDiskAccess() {
    model.openFullDiskAccessSettings()
  }
}

// MARK: - Freed chart

private struct FreedChart: View {
  let months: [MonthBar]
  @State private var grown = false

  private static let maxBarHeight: CGFloat = 80

  var body: some View {
    let peak = max(months.map(\.bytes).max() ?? 0, 1)
    let total = months.reduce(UInt64(0)) { $0 + $1.bytes }
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text("Освобождено за полгода").font(.system(size: 13, weight: .semibold))
        Spacer(minLength: 8)
        SizeText(bytes: total, font: .system(size: 22, weight: .bold))
      }
      HStack(alignment: .bottom, spacing: 14) {
        ForEach(Array(months.enumerated()), id: \.element.id) { index, month in
          VStack(spacing: 6) {
            Text(month.bytes > 0 ? ByteFormat.string(month.bytes) : "0")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(Color.primary.opacity(0.75))
              .monospacedDigit()
              .lineLimit(1)
              .minimumScaleFactor(0.8)
              .opacity(grown ? 1 : 0)
              .offset(y: grown || Motion.reduced ? 0 : 4)
              .animation(barAnimation(index, base: 0.6, bouncy: false), value: grown)
            bar(month, height: barHeight(month.bytes, peak: peak))
              .scaleEffect(y: grown ? 1 : 0, anchor: .bottom)
              .animation(barAnimation(index, base: 0.25, bouncy: true), value: grown)
              .animation(Motion.resolve(Motion.smooth), value: month.bytes)
              .help(ByteFormat.string(month.bytes))
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
      }
      .frame(height: 100)
      .padding(.top, 18)
      HStack(spacing: 14) {
        ForEach(months) { month in
          Text(month.label)
            .font(.system(size: 11, weight: month.isCurrent ? .semibold : .regular))
            .foregroundStyle(month.isCurrent ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity)
        }
      }
      .padding(.top, 6)
    }
    .padding(.horizontal, 20)
    .padding(.top, 16)
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.sectorCard, in: .rect(cornerRadius: Metrics.cardRadius))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.cardRadius)
        .strokeBorder(Color.sectorHairline, lineWidth: 0.5)
    )
    .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
    .onAppear { grown = true }
    .accessibilityElement(children: .combine)
  }

  private func barHeight(_ bytes: UInt64, peak: UInt64) -> CGFloat {
    guard bytes > 0 else { return 4 }
    return max(8, Self.maxBarHeight * CGFloat(Double(bytes) / Double(peak)))
  }

  private func bar(_ month: MonthBar, height: CGFloat) -> some View {
    UnevenRoundedRectangle(
      topLeadingRadius: 8, bottomLeadingRadius: 4, bottomTrailingRadius: 4,
      topTrailingRadius: 8
    )
    .fill(
      month.isCurrent
        ? AnyShapeStyle(
          LinearGradient(
            colors: [Color(hex: 0x5E5CE6), .sectorAccent], startPoint: .top, endPoint: .bottom))
        : AnyShapeStyle(Color.sectorAccent.opacity(0.28))
    )
    .frame(maxWidth: 56)
    .frame(height: height)
  }

  private func barAnimation(_ index: Int, base: Double, bouncy: Bool) -> Animation {
    if Motion.reduced { return Motion.resolve(Motion.quick) }
    let curve = bouncy ? Animation.spring(duration: 0.8, bounce: 0.25) : .easeOut(duration: 0.4)
    return curve.delay(base + Double(index) * 0.09)
  }
}

// MARK: - Trash card

private struct TrashCard: View {
  let snapshot: TrashSnapshot?
  let restorableBytes: UInt64
  let keepDays: Int
  let isEmptying: Bool
  let openSettings: () -> Void
  let onEmpty: () -> Void

  @State private var grown = false

  var body: some View {
    let trashColors = CleanupSource.trash.colors
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "trash")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(trashColors.icon)
          .frame(width: 36, height: 36)
          .background(trashColors.tint, in: .rect(cornerRadius: 11))
        VStack(alignment: .leading, spacing: 1) {
          Text("В Корзине сейчас").font(.system(size: 13, weight: .semibold))
          Text("Можно вернуть в исходные папки")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }

      Group {
        if let snapshot, snapshot.accessible {
          SizeText(bytes: snapshot.size, font: .system(size: 30, weight: .bold))
        } else if snapshot != nil {
          Text(verbatim: "—").font(.system(size: 30, weight: .bold))
        } else {
          ProgressView().controlSize(.small).frame(height: 36)
        }
      }
      .padding(.top, 10)

      Capsule()
        .fill(Color.sectorTrack)
        .frame(height: 6)
        .overlay(alignment: .leading) {
          GeometryReader { geo in
            Capsule()
              .fill(DiskCategory.trash.color)
              .frame(width: geo.size.width * fraction)
              .scaleEffect(x: grown ? 1 : 0, anchor: .leading)
          }
        }
        .clipShape(.capsule)
        .padding(.top, 6)
        .animation(Motion.resolve(Motion.smooth), value: fraction)

      caption.padding(.top, 6)

      Spacer(minLength: 10)

      Button(action: onEmpty) {
        HStack(spacing: 6) {
          if isEmptying { ProgressView().controlSize(.mini) }
          Text("Очистить Корзину сейчас")
        }
        .font(.system(size: 12, weight: .semibold))
      }
      .buttonStyle(.glass)
      .disabled(isEmptying || (snapshot?.items.isEmpty ?? true))
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.sectorCard, in: .rect(cornerRadius: Metrics.cardRadius))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.cardRadius)
        .strokeBorder(Color.sectorHairline, lineWidth: 0.5)
    )
    .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
    .onAppear {
      withAnimation(Motion.resolve(Motion.smooth).delay(Motion.reduced ? 0 : 0.4)) {
        grown = true
      }
    }
  }

  /// Share of the Trash that Sector put there and can still restore.
  private var fraction: Double {
    guard let snapshot, snapshot.size > 0 else { return 0 }
    return min(1, Double(restorableBytes) / Double(snapshot.size))
  }

  @ViewBuilder private var caption: some View {
    if let snapshot, !snapshot.accessible {
      Button(action: openSettings) {
        Text("Нет доступа к Корзине · открыть настройки доступа")
          .font(.system(size: 11))
      }
      .buttonStyle(.link)
    } else {
      HStack(spacing: 4) {
        Text(
          String(
            localized:
              "Автоочистка через \(Plural.format(keepDays, "день", "дня", "дней")) ·"))
        SettingsLink {
          Text("настраивается")
        }
        .buttonStyle(.link)
      }
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Journal row

private struct HistoryRow: View {
  enum RowState: Equatable {
    case checking
    case restorable
    case restored
    case gone(String)
  }

  let record: CleanupRecord
  let state: RowState
  let isNew: Bool
  let onRestore: () -> Void

  @State private var hovered = false

  var body: some View {
    let colors = record.source.colors
    HStack(spacing: 12) {
      Image(systemName: record.source.symbol)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(colors.icon)
        .frame(width: 34, height: 34)
        .background(colors.tint, in: .rect(cornerRadius: 10))

      VStack(alignment: .leading, spacing: 1) {
        Text(HistoryFormat.title(record))
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
        Text(HistoryFormat.detail(record))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      TimelineView(.everyMinute) { context in
        Text(HistoryFormat.when(record.date, now: context.date))
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(width: 110, alignment: .leading)

      Text(ByteFormat.string(record.freedBytes))
        .font(.system(size: 13, weight: .semibold))
        .monospacedDigit()
        .strikethrough(state == .restored)
        .foregroundStyle(state == .restored ? Color.secondary : Color.primary)
        .lineLimit(1)
        .frame(width: 72, alignment: .trailing)

      action
        .frame(width: 150, alignment: .trailing)
    }
    .padding(.leading, 12)
    .padding(.trailing, 14)
    .frame(height: 62)
    .background(background, in: .rect(cornerRadius: 16))
    .overlay(
      RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
    )
    .overlay(alignment: .leading) {
      TimelineDot(isNew: isNew && state != .restored).offset(x: -22)
    }
    .onHover { h in
      withAnimation(Motion.resolve(Motion.quick)) { hovered = h }
    }
    .animation(Motion.resolve(Motion.bouncy), value: state)
  }

  private var background: Color {
    if hovered { return Color.sectorCard.opacity(1) }
    return isNew && state != .restored ? Color.sectorCard : Color.sectorCard.opacity(0.62)
  }

  @ViewBuilder private var action: some View {
    switch state {
    case .checking:
      EmptyView()
    case .restorable:
      Button(action: onRestore) {
        Label("Восстановить", systemImage: "arrow.uturn.backward")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Color.sectorAccent)
      }
      .buttonStyle(.glass)
      .transition(.opacity)
    case .restored:
      Label("Восстановлено", systemImage: "checkmark")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.sectorSuccess)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color(hex: 0x34C759, opacity: 0.14), in: .capsule)
        .transition(.scale(scale: 0.5).combined(with: .opacity))
    case .gone(let text):
      Text(text)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 4)
        .transition(.opacity)
    }
  }
}

/// Vertical line on the left of the journal; grows down on appear.
private struct TimelineLine: View {
  @State private var grown = false

  var body: some View {
    Capsule()
      .fill(
        LinearGradient(
          colors: [.sectorAccent, Color.primary.opacity(0.1)], startPoint: .top, endPoint: .bottom)
      )
      .frame(width: 2)
      .padding(.vertical, 30)
      .scaleEffect(y: grown ? 1 : 0, anchor: .top)
      .padding(.leading, 22)
      .onAppear {
        withAnimation(
          Motion.resolve(.spring(duration: 1.2, bounce: 0)).delay(Motion.reduced ? 0 : 0.3)
        ) {
          grown = true
        }
      }
      .accessibilityHidden(true)
  }
}

/// Timeline marker; the newest cleanup is filled and pulses.
private struct TimelineDot: View {
  let isNew: Bool
  @State private var shown = false

  var body: some View {
    ZStack {
      if isNew && !Motion.reduced {
        Circle()
          .fill(Color.sectorAccent)
          .keyframeAnimator(initialValue: CGFloat(0), repeating: true) { content, p in
            content.scaleEffect(1 + 1.6 * p).opacity(0.45 * (1 - p))
          } keyframes: { _ in
            KeyframeTrack {
              LinearKeyframe(0, duration: 1.2)
              CubicKeyframe(1, duration: 1.6)
            }
          }
      }
      Circle()
        .fill(isNew ? Color.sectorAccent : Color.dotFill)
        .overlay(
          Circle().strokeBorder(
            isNew ? Color.sectorAccent : Color.primary.opacity(0.2), lineWidth: 2))
    }
    .frame(width: 12, height: 12)
    .scaleEffect(shown ? 1 : 0)
    .onAppear {
      withAnimation(Motion.resolve(Motion.bouncy).delay(Motion.reduced ? 0 : 0.45)) { shown = true }
    }
    .accessibilityHidden(true)
  }
}

extension Color {
  fileprivate static let dotFill = Color(light: 0xFFFFFF, dark: 0x2C2C2E)
}

// MARK: - Layout

/// Splits the width between children by `ratios` (CSS `1.6fr 1fr`) and gives
/// them all the tallest child's height.
private struct RatioHStack: Layout {
  var ratios: [CGFloat]
  var spacing: CGFloat

  private func widths(_ total: CGFloat, count: Int) -> [CGFloat] {
    guard count > 0 else { return [] }
    let available = max(0, total - spacing * CGFloat(count - 1))
    let parts = (0..<count).map { $0 < ratios.count ? ratios[$0] : 1 }
    let sum = parts.reduce(0, +)
    return parts.map { available * $0 / sum }
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 720
    let ws = widths(width, count: subviews.count)
    let height =
      zip(subviews, ws)
      .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
      .max() ?? 0
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var x = bounds.minX
    for (subview, width) in zip(subviews, widths(bounds.width, count: subviews.count)) {
      subview.place(
        at: CGPoint(x: x, y: bounds.minY),
        proposal: ProposedViewSize(width: width, height: bounds.height))
      x += width + spacing
    }
  }
}
