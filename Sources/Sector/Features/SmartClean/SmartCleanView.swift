import SectorCore
import SwiftUI

/// Smart Clean route: review → cleaning → done, as states of one screen
/// (design/mockups/SmartClean, Cleaning and Done).
struct SmartCleanView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    let model = app.smartClean
    ZStack {
      switch model.phase {
      case .review:
        SmartCleanReviewView(model: model)
          .transition(.opacity.combined(with: .offset(y: 10)))
      case .cleaning:
        CleaningView(model: model)
          .transition(.opacity.combined(with: .scale(scale: 0.98)))
      case .done:
        CleanDoneView(model: model)
          .transition(.opacity.combined(with: .scale(scale: 1.02)))
      }
    }
    .animation(Motion.resolve(Motion.smooth), value: model.phase)
    .onDisappear {
      if model.phase == .done { model.dismissSummary() }
    }
  }
}

// MARK: - Review

/// Categories with per-item selection and the "Очистить" bar.
struct SmartCleanReviewView: View {
  @Environment(AppModel.self) private var app
  let model: SmartCleanModel

  var body: some View {
    Group {
      if model.categories.isEmpty && (!model.hasAnalyzed || model.isAnalyzing) {
        VStack(spacing: 12) {
          ProgressView().controlSize(.large)
          Text("Ищем, что можно удалить…").font(.sectorBody).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
      } else if model.categories.isEmpty {
        EmptyStateView(
          symbol: "sparkles", title: "Всё чисто",
          message: "Ничего лишнего не нашлось. Загляните после следующего сканирования.")
          .transition(.opacity)
      } else {
        content.transition(.opacity)
      }
    }
    .animation(Motion.resolve(Motion.smooth), value: model.categories.isEmpty)
    .navigationTitle("Умная очистка")
    .navigationSubtitle(subtitle)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button("Выбрать безопасное") {
          withAnimation(Motion.resolve(Motion.quick)) { model.selectSafe() }
        }
        .disabled(model.categories.isEmpty)
        Button {
          app.startScan()
        } label: {
          Label("Сканировать снова", systemImage: "arrow.clockwise")
        }
        .help("Сканировать снова")
        .disabled(app.isScanning)
      }
    }
  }

  private var subtitle: String {
    if model.categories.isEmpty {
      return model.hasAnalyzed && !model.isAnalyzing ? "" : String(localized: "Анализ…")
    }
    let count = Plural.format(model.categories.count, "категория", "категории", "категорий")
    return String(localized: "\(count) · найдено \(ByteFormat.string(model.foundBytes))")
  }

  private var content: some View {
    VStack(spacing: 12) {
      SummaryCard(model: model)
        .appearAnimation(delay: 0.1)
        .padding(.horizontal, 20)
      ScrollView {
        LazyVStack(spacing: 6) {
          ForEach(Array(model.categories.enumerated()), id: \.element.id) { index, category in
            CategoryRow(model: model, category: category)
              .modifier(RowIn(delay: 0.18 + Double(min(index, 10)) * 0.055))
          }
        }
        .padding(.horizontal, 20)
        .animation(Motion.resolve(Motion.smooth), value: model.expanded)
        .animation(Motion.resolve(Motion.smooth), value: model.categories.map(\.id))
      }
      .contentMargins(.bottom, 94, for: .scrollContent)
      .scrollEdgeEffectStyle(.soft, for: .bottom)
    }
    .padding(.top, 8)
    .overlay(alignment: .bottom) {
      CleanBar(model: model)
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .appearAnimation(delay: 0.5)
    }
  }
}

/// The mock's `rowIn`: fade, lift and a slight scale.
private struct RowIn: ViewModifier {
  var delay: Double
  @State private var visible = false

  func body(content: Content) -> some View {
    content
      .opacity(visible ? 1 : 0)
      .scaleEffect(visible || Motion.reduced ? 1 : 0.98)
      .offset(y: visible || Motion.reduced ? 0 : 10)
      .onAppear {
        withAnimation(Motion.resolve(Motion.smooth).delay(Motion.reduced ? 0 : delay)) {
          visible = true
        }
      }
  }
}

// MARK: - Summary

/// Gauge, "Будет освобождено" and the before/after free space bars.
private struct SummaryCard: View {
  @Environment(AppModel.self) private var app
  let model: SmartCleanModel

  var body: some View {
    let selected = model.selectedBytes
    let found = max(1, model.foundBytes)
    let available = app.volume?.available ?? 0
    let total = max(1, app.volume?.total ?? 1)
    let after = min(total, available + selected)

    HStack(spacing: 22) {
      GaugeArc(fraction: Double(selected) / Double(found))
        .frame(width: 128, height: 76)

      VStack(alignment: .leading, spacing: 0) {
        Text("Будет освобождено").font(.system(size: 12)).foregroundStyle(.secondary)
        AnimatedBytesText(bytes: selected, font: .system(size: 40, weight: .bold))
          .tracking(-1)
          .frame(height: 46)
        Text(countText).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.8))
          .contentTransition(.numericText())
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text("Сейчас свободно")
          Spacer()
          Text(ByteFormat.string(available)).monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        GrowingBar(
          fraction: Double(available) / Double(total), fill: Color(hex: 0x8E8E93), delay: 0.3
        )
        .padding(.top, 5)
        .padding(.bottom, 10)
        HStack {
          Text("После очистки")
          Spacer()
          AnimatedBytesText(bytes: after, font: .system(size: 11, weight: .semibold))
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.sectorSuccess)
        GrowingBar(
          fraction: Double(after) / Double(total),
          fill: LinearGradient(
            colors: [Color(hex: 0x34C759), Color(hex: 0x30B0C7)], startPoint: .leading,
            endPoint: .trailing),
          delay: 0.5
        )
        .padding(.top, 5)
      }
      .frame(width: 250)
    }
    .padding(.vertical, 16)
    .padding(.horizontal, 24)
    .background(Color.sectorCard, in: .rect(cornerRadius: Metrics.cardRadius))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.cardRadius)
        .strokeBorder(Color.sectorHairline, lineWidth: 0.5)
    )
    .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
  }

  /// "7 из 8 категорий выбрано · без загрузок"
  private var countText: String {
    let total = model.categories.count
    let chosen = model.selectedCategoryCount
    let of = Plural.format(total, "категории", "категорий", "категорий")
    var text = String(localized: "\(chosen) из \(of) выбрано")
    if model.categories.contains(where: { $0.kind == .downloads }) {
      text +=
        " · "
        + (model.isSelected(.downloads)
          ? String(localized: "включая загрузки") : String(localized: "без загрузок"))
    }
    return text
  }
}

/// Half-ring showing the selected share of everything found.
private struct GaugeArc: View {
  var fraction: Double
  @State private var twinkle = false

  var body: some View {
    ZStack(alignment: .top) {
      HalfRing().stroke(Color.sectorTrack, style: StrokeStyle(lineWidth: 12, lineCap: .round))
      HalfRing()
        .trim(from: 0, to: max(0.001, min(1, fraction)))
        .stroke(LinearGradient.sectorClean(), style: StrokeStyle(lineWidth: 12, lineCap: .round))
        .animation(Motion.resolve(Motion.smooth), value: fraction)
      Image(systemName: "sparkle")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(Color(hex: 0x5E5CE6))
        .scaleEffect(twinkle ? 0.7 : 1)
        .rotationEffect(.degrees(twinkle ? 25 : 0))
        .opacity(twinkle ? 0.6 : 1)
        .offset(y: 34)
    }
    .onAppear {
      guard !Motion.reduced else { return }
      withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { twinkle = true }
    }
    .accessibilityHidden(true)
  }
}

/// Upper half of a circle whose diameter spans the frame width (inset by
/// the stroke), sitting on the bottom edge.
private struct HalfRing: Shape {
  func path(in rect: CGRect) -> Path {
    let radius = rect.width / 2 - 10
    var path = Path()
    path.addArc(
      center: CGPoint(x: rect.midX, y: rect.maxY - 8), radius: radius,
      startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
    return path
  }
}

// MARK: - Category row

private struct CategoryRow: View {
  @Environment(AppModel.self) private var app
  let model: SmartCleanModel
  let category: CleanupCategory
  @State private var showsAll = false

  private static let visibleItems = 5

  var body: some View {
    let state = model.state(of: category)
    let isOn = state != .off
    let isOpen = model.expanded == category.kind

    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: category.symbol)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(category.kind.color)
          .frame(width: 34, height: 34)
          .background(category.kind.color.opacity(0.14), in: .rect(cornerRadius: Metrics.iconRadius))
          .opacity(isOn ? 1 : 0.5)

        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 6) {
            Text(category.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if category.safety == .review { SafetyBadge(kind: .review) }
          }
          Text(category.description)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Text(ByteFormat.string(category.size))
          .font(.system(size: 13, weight: .semibold))
          .monospacedDigit()
          .foregroundStyle(isOn ? Color.primary : Color.secondary)
          .frame(minWidth: 70, alignment: .trailing)

        Button {
          model.expanded = isOpen ? nil : category.kind
        } label: {
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isOpen ? 90 : 0))
            .frame(width: 26, height: 26)
            .contentShape(.circle)
        }
        .buttonStyle(ChevronButtonStyle())
        .accessibilityLabel(
          isOpen ? Text("Свернуть \(category.title)") : Text("Подробнее: \(category.title)"))
        .animation(Motion.resolve(Motion.bouncy), value: isOpen)

        Toggle(
          isOn: Binding(
            get: { isOn },
            set: { _ in withAnimation(Motion.resolve(Motion.quick)) { model.toggle(category) } })
        ) {
          isOn ? Text("Не очищать: \(category.title)") : Text("Очищать: \(category.title)")
        }
        .toggleStyle(.switch)
        .labelsHidden()
      }
      .frame(height: 52)
      .padding(.leading, 10)
      .padding(.trailing, 12)
      .contentShape(.rect)
      .onTapGesture { model.expanded = isOpen ? nil : category.kind }

      if isOpen {
        items
          .padding(.leading, 56)
          .padding(.trailing, 12)
          .padding(.bottom, 10)
          .transition(.opacity.combined(with: .offset(y: -6)))
      }
    }
    .background(
      Color.sectorCard.opacity(isOpen ? 1 : 0.85), in: .rect(cornerRadius: 16)
    )
    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.sectorHairline, lineWidth: 0.5))
    .shadow(color: .black.opacity(isOpen ? 0.08 : 0), radius: 12, y: 8)
    .animation(Motion.resolve(Motion.quick), value: isOn)
  }

  @ViewBuilder private var items: some View {
    let all = category.items
    let limit = showsAll || all.count <= Self.visibleItems + 1 ? all.count : Self.visibleItems
    VStack(spacing: 0) {
      ForEach(all.prefix(limit)) { item in
        ItemRow(model: model, category: category, item: item)
      }
      if limit < all.count {
        let rest = all.dropFirst(limit)
        let noun = category.kind.itemNoun
        Button {
          withAnimation(Motion.resolve(Motion.smooth)) { showsAll = true }
        } label: {
          HStack(spacing: 8) {
            Text("ещё \(Plural.format(rest.count, noun.0, noun.1, noun.2))")
              .foregroundStyle(Color.sectorAccent)
            Spacer()
            Text(ByteFormat.string(rest.reduce(0) { $0 + $1.size }))
              .fontWeight(.semibold)
              .monospacedDigit()
              .foregroundStyle(.secondary)
              .frame(minWidth: 66, alignment: .trailing)
          }
          .font(.system(size: 12))
          .frame(height: 28)
          .padding(.leading, 24)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(Color.sectorHairline).frame(height: 0.5) }
      }
    }
  }
}

private struct ItemRow: View {
  @Environment(AppModel.self) private var app
  let model: SmartCleanModel
  let category: CleanupCategory
  let item: CleanupItem

  var body: some View {
    let isOn = model.isSelected(item)
    HStack(spacing: 8) {
      SelectionCheck(isOn: isOn, size: 16)
      Text(item.name)
        .foregroundStyle(.primary.opacity(isOn ? 0.85 : 0.5))
        .lineLimit(1)
        .truncationMode(.middle)
      if item.safety == .review && category.safety == .safe {
        SafetyBadge(kind: .review).scaleEffect(0.9)
      }
      Spacer(minLength: 8)
      Text(item.detail)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.head)
      Text(ByteFormat.string(item.size))
        .fontWeight(.semibold)
        .monospacedDigit()
        .foregroundStyle(isOn ? Color.primary : Color.secondary)
        .frame(minWidth: 66, alignment: .trailing)
    }
    .font(.system(size: 12))
    .frame(height: 28)
    .contentShape(.rect)
    .onTapGesture {
      withAnimation(Motion.resolve(Motion.quick)) { model.toggle(item) }
    }
    .overlay(alignment: .top) { Rectangle().fill(Color.sectorHairline).frame(height: 0.5) }
    .contextMenu {
      if case .files(let files) = item.target, !files.isEmpty {
        Button("Показать в Finder") {
          app.revealInFinder(files.prefix(50).map(\.url))
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

private struct ChevronButtonStyle: ButtonStyle {
  @State private var hovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(Color.primary.opacity(hovering ? 0.06 : 0), in: .circle)
      .scaleEffect(configuration.isPressed ? 0.92 : 1)
      .onHover { hovering = $0 }
      .animation(Motion.resolve(Motion.quick), value: hovering)
  }
}

// MARK: - Bottom bar

private struct CleanBar: View {
  @Environment(AppModel.self) private var app
  let model: SmartCleanModel

  var body: some View {
    let selected = model.selectedBytes
    let irreversible = irreversibleSelection
    HStack(spacing: 14) {
      Image(systemName: irreversible == nil ? "checkmark.shield" : "exclamationmark.shield")
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(irreversible == nil ? Color.sectorSuccess : Color.sectorWarning)
        .contentTransition(.symbolEffect(.replace))
      VStack(alignment: .leading, spacing: 1) {
        Text(irreversible ?? String(localized: "Только восстанавливаемые данные"))
          .font(.system(size: 13, weight: .semibold))
          .contentTransition(.opacity)
        Text(note)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button {
        model.cleanSelection()
      } label: {
        AnimatedBytesText(bytes: selected, font: .system(size: 14, weight: .semibold)) {
          String(localized: "Очистить \($0)")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
      }
      .buttonStyle(.glassProminent)
      .controlSize(.large)
      .modifier(SelectionShimmer(active: selected > 0))
      .disabled(selected == 0)
    }
    .padding(.leading, 20)
    .padding(.trailing, 10)
    .frame(height: 62)
    .glassEffect(.regular, in: .rect(cornerRadius: Metrics.cardRadius))
    .shadow(color: .black.opacity(0.1), radius: 20, y: 10)
    .animation(Motion.resolve(Motion.quick), value: irreversible)
  }

  /// Title when the selection includes data that cannot come back.
  private var irreversibleSelection: String? {
    let trash = model.isSelected(.trash)
    let volumes = model.categories.first { $0.kind == .docker }?.items
      .contains { $0.id == "docker.volumes" && model.isSelected($0) } ?? false
    switch (trash, volumes) {
    case (true, true): return String(localized: "Корзина и тома Docker удалятся безвозвратно")
    case (true, false): return String(localized: "Корзина очистится безвозвратно")
    case (false, true): return String(localized: "Тома Docker удалятся безвозвратно")
    default: return nil
    }
  }

  private var note: String {
    var text = String(localized: "Кэши и сборки пересоздадутся сами.")
    if model.isSelected(.downloads) {
      let days = Plural.format(app.settings.keepDays, "день", "дня", "дней")
      text += " " + String(localized: "Загрузки — через «Историю» \(days).")
    }
    return text
  }
}
