import AppKit
import SectorCore
import SwiftUI

/// The menu bar panel (design/mockups/MenuBar.dc.html): disk ring and
/// forecast, category bar, Smart Clean card, Trash, Downloads, other
/// volumes, and shortcuts to the main window and Settings.
struct MenuBarView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  /// Bumped every time the panel opens, so the pop-in plays again.
  @State private var session = 0
  @State private var openedOnce = false
  @State private var trash: [DeletionItem]?
  @State private var downloadsSize: UInt64?
  @State private var ejecting: Set<URL> = []
  @State private var ejectFailed: URL?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding([.horizontal, .top], 4)
        .padding(.bottom, 12)
        .appearAnimation(delay: 0.1, offset: 8)
      MenuCategoryBar(segments: segments)
        .padding(.horizontal, 4)
        .padding(.bottom, 12)
      MenuSmartCleanCard(action: cardAction)
        .appearAnimation(delay: 0.18, offset: 8)
      rows.padding(.top, 8)
      Divider().padding(.vertical, 8).padding(.horizontal, 4)
      footer.appearAnimation(delay: 0.42 + Double(otherVolumes.count) * 0.06, offset: 8)
    }
    .id(session)
    .padding(14)
    .frame(width: 356)
    .background(PanelLifecycle(onOpen: opened))
    .task(id: session) { await loadFolders() }
    .capturesOpenWindow()
  }

  private func opened() {
    model.refreshVolume()
    if openedOnce { session += 1 } else { openedOnce = true }
  }

  // MARK: - Header

  @ViewBuilder private var header: some View {
    if let volume = model.volume {
      HStack(spacing: 14) {
        UsageRing(fraction: volume.usedFraction, color: ringColor(volume))
          .frame(width: 68, height: 68)
        VStack(alignment: .leading, spacing: 0) {
          Text(volume.name)
            .font(.system(size: 14, weight: .bold))
            .lineLimit(1)
          Text(
            "\(ByteFormat.string(volume.available)) свободно из \(ByteFormat.string(volume.total))"
          )
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          if let days = model.history.daysUntilFull(available: volume.available),
            days < ForecastText.horizonDays
          {
            ForecastPill(text: "Заполнится примерно через \(ForecastText.duration(days: days))")
              .padding(.top, 5)
          }
        }
        Spacer(minLength: 0)
      }
    }
  }

  private func ringColor(_ volume: VolumeInfo) -> Color {
    let critical =
      volume.available < AppModel.bytes(gigabytes: model.settings.lowSpaceThresholdGB)
      || volume.usedFraction > 0.95
    return critical ? .sectorDanger : .sectorAccent
  }

  /// Category shares of the whole disk; a single "used" segment until the
  /// first scan.
  private var segments: [MenuCategoryBar.Segment] {
    guard let volume = model.volume, volume.total > 0 else { return [] }
    guard let breakdown = model.breakdown else {
      return [.init(id: "used", fraction: volume.usedFraction, color: .sectorAccent)]
    }
    let ordered = breakdown.ordered
    let sum = ordered.reduce(0) { $0 + $1.size }
    let total = Double(max(volume.total, sum))
    return ordered.map {
      .init(id: $0.category.rawValue, fraction: Double($0.size) / total, color: $0.category.color)
    }
  }

  // MARK: - Smart Clean

  private var cardAction: MenuSmartCleanCard.Model {
    let reclaimable = model.smartClean.reclaimableBytes
    if model.isScanning {
      return .init(title: "Идёт сканирование…", button: "Открыть") {
        AppWindow.showMain()
        model.showsScan = true
      }
    }
    if model.tree == nil {
      return .init(title: "Диск ещё не проверен", button: "Сканировать") {
        AppWindow.showMain()
        model.startScan()
      }
    }
    if reclaimable > 0 {
      return .init(
        title: "\(ByteFormat.string(reclaimable)) можно освободить", button: "Очистить",
        shimmer: true
      ) {
        model.startQuickClean()
        dismiss()
      }
    }
    let title: LocalizedStringKey =
      model.smartClean.isAnalyzing ? "Ищем, что можно освободить…" : "Нечего очищать"
    return .init(title: title, button: "Открыть") {
      model.presentInMainWindow(.smartClean)
      dismiss()
    }
  }

  // MARK: - Rows

  private var otherVolumes: [VolumeInfo] {
    model.volumes.filter { $0.url.path != "/" }
  }

  private var rows: some View {
    VStack(spacing: 2) {
      MenuRow(symbol: "trash", color: Color(hex: 0xA2845E), delay: 0.24) {
        Text("Корзина").font(.system(size: 13))
      } trailing: {
        sizeLabel(trashSize)
        Button("Очистить", action: emptyTrash)
          .buttonStyle(MenuCapsuleButtonStyle())
          .disabled((trash ?? []).isEmpty)
      }
      MenuRow(symbol: "arrow.down.to.line", color: Color(hex: 0x30B0C7), delay: 0.30) {
        Text("Загрузки").font(.system(size: 13))
      } trailing: {
        sizeLabel(downloadsSize ?? treeSize(FolderSize.downloadsURL))
        Button("Разобрать") {
          model.presentInMainWindow(.largeFiles)
          dismiss()
        }
        .buttonStyle(MenuCapsuleButtonStyle())
      }
      ForEach(Array(otherVolumes.enumerated()), id: \.element.id) { index, volume in
        volumeRow(volume, delay: 0.36 + Double(index) * 0.06)
          .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
      }
    }
    .animation(Motion.resolve(Motion.smooth), value: otherVolumes.map(\.id))
  }

  private func volumeRow(_ volume: VolumeInfo, delay: Double) -> some View {
    MenuRow(
      symbol: volume.isNetwork ? "network" : "externaldrive", color: .secondary, delay: delay
    ) {
      VStack(alignment: .leading, spacing: 0) {
        Text(volume.name).font(.system(size: 13)).lineLimit(1)
        Group {
          if ejectFailed == volume.url {
            Text("Не удалось извлечь — диск занят").foregroundStyle(Color.sectorDanger)
          } else {
            Text(
              "\(ByteFormat.string(volume.available)) свободно из \(ByteFormat.string(volume.total))"
            )
            .foregroundStyle(.tertiary)
          }
        }
        .font(.system(size: 11))
        .monospacedDigit()
      }
    } trailing: {
      Button {
        eject(volume)
      } label: {
        Group {
          if ejecting.contains(volume.url) {
            ProgressView().controlSize(.mini)
          } else {
            Image(systemName: "eject").font(.system(size: 11, weight: .semibold))
          }
        }
        .frame(width: 26, height: 26)
        .background(Color.primary.opacity(0.06), in: .circle)
        .contentShape(.circle)
      }
      .buttonStyle(MenuPressStyle())
      .disabled(ejecting.contains(volume.url))
      .help(Text("Извлечь «\(volume.name)»"))
      .accessibilityLabel(Text("Извлечь \(volume.name)"))
    }
  }

  private func sizeLabel(_ bytes: UInt64?) -> some View {
    Text(bytes.map { ByteFormat.string($0) } ?? "—")
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
      .monospacedDigit()
      .contentTransition(.numericText(value: Double(bytes ?? 0)))
  }

  private var trashSize: UInt64? {
    if let trash { return trash.reduce(0) { $0 + $1.size } }
    return treeSize(FolderSize.trashURL)
  }

  private func treeSize(_ url: URL) -> UInt64? {
    guard let tree = model.tree, let id = tree.find(path: url.path) else { return nil }
    return tree.size(id)
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 6) {
      Button {
        AppWindow.showMain()
        dismiss()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "macwindow")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.sectorAccent)
          Text("Открыть Sector").font(.system(size: 13, weight: .medium))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
      }
      .buttonStyle(MenuHoverStyle())
      SettingsLink {
        Image(systemName: "gearshape")
          .font(.system(size: 15))
          .foregroundStyle(.secondary)
          .frame(width: 32, height: 32)
          .contentShape(.circle)
      }
      .buttonStyle(MenuPressStyle())
      .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
      .help(Text("Настройки"))
      .accessibilityLabel(Text("Настройки"))
    }
  }

  // MARK: - Actions

  private func loadFolders() async {
    async let trashItems = FolderSize.trashContents()
    async let downloads = FolderSize.allocated(FolderSize.downloadsURL)
    let (items, size) = await (trashItems, downloads)
    withAnimation(Motion.resolve(Motion.quick)) {
      trash = items
      downloadsSize = size
    }
  }

  private func emptyTrash() {
    guard let items = trash, !items.isEmpty else { return }
    let request = DeletionRequest(
      items: items, source: .trash, recordTitle: String(localized: "Корзина")
    ) { _ in
      Task { await loadFolders() }
    }
    if model.settings.alwaysConfirm {
      // The confirmation sheet lives in the main window.
      AppWindow.showMain()
      model.requestDeletion(request)
      dismiss()
    } else {
      // Items already in the Trash can only be deleted for good.
      Task { await model.perform(request, mode: .permanent) }
    }
  }

  private func eject(_ volume: VolumeInfo) {
    let url = volume.url
    let options: FileManager.UnmountOptions = volume.isNetwork ? [] : [.allPartitionsAndEjectDisk]
    ejecting.insert(url)
    ejectFailed = nil
    Task {
      let ok: Bool
      do {
        try await FileManager.default.unmountVolume(at: url, options: options)
        ok = true
      } catch {
        ok = false
      }
      ejecting.remove(url)
      if ok {
        model.refreshVolume()
      } else {
        withAnimation(Motion.resolve(Motion.quick)) { ejectFailed = url }
      }
    }
  }
}

// MARK: - Pieces

/// Used-space ring that draws itself in when the panel opens.
private struct UsageRing: View {
  var fraction: Double
  var color: Color
  @State private var shown: Double = 0

  var body: some View {
    ZStack {
      ProgressRing(fraction: shown, lineWidth: 9, color: color)
      Text("\(Int((fraction * 100).rounded()))%")
        .font(.system(size: 13, weight: .bold))
        .monospacedDigit()
    }
    .onAppear {
      withAnimation(stagedAnimation(.spring(duration: 1.2, bounce: 0), delay: 0.2)) {
        shown = fraction
      }
    }
    .onChange(of: fraction) { _, new in
      withAnimation(Motion.resolve(Motion.smooth)) { shown = new }
    }
  }
}

/// "Заполнится примерно через 2 месяца" with a blinking dot.
private struct ForecastPill: View {
  var text: LocalizedStringKey
  @State private var dim = false

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(Color.sectorWarningFill)
        .frame(width: 6, height: 6)
        .opacity(dim ? 0.35 : 1)
      Text(text)
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
    }
    .foregroundStyle(Color.sectorWarning)
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    .background(Color.sectorWarningFill.opacity(0.15), in: .rect(cornerRadius: 8))
    .onAppear {
      guard !Motion.reduced else { return }
      withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
    }
  }
}

/// Thin stacked bar of categories; segments grow in one after another.
struct MenuCategoryBar: View {
  struct Segment: Identifiable {
    var id: String
    var fraction: Double
    var color: Color
  }

  var segments: [Segment]
  @State private var grown = false

  var body: some View {
    GeometryReader { geo in
      HStack(spacing: 2) {
        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
          Rectangle()
            .fill(segment.color)
            .frame(width: max(1, geo.size.width * segment.fraction - 2))
            .scaleEffect(x: grown ? 1 : 0, anchor: .leading)
            .animation(
              stagedAnimation(.spring(duration: 0.6, bounce: 0), delay: 0.25 + Double(index) * 0.07),
              value: grown)
        }
        Spacer(minLength: 0)
      }
    }
    .frame(height: 8)
    .background(Color.primary.opacity(0.06))
    .clipShape(.rect(cornerRadius: 4))
    .onAppear { grown = true }
    .accessibilityHidden(true)
  }
}

/// Gradient card: "64,8 ГБ можно освободить" + "Очистить".
private struct MenuSmartCleanCard: View {
  struct Model {
    var title: LocalizedStringKey
    var button: LocalizedStringKey
    var shimmer = false
    var perform: @MainActor () -> Void
  }

  var action: Model

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text("Умная очистка")
          .font(.system(size: 11))
          .opacity(0.9)
        Text(action.title)
          .font(.system(size: 18, weight: .bold))
          .monospacedDigit()
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .contentTransition(.numericText())
      }
      Spacer(minLength: 0)
      Button(action: action.perform) {
        Text(action.button)
      }
      .buttonStyle(WhitePillButtonStyle(shimmer: action.shimmer))
    }
    .foregroundStyle(.white)
    .padding(.vertical, 12)
    .padding(.leading, 14)
    .padding(.trailing, 12)
    .background(
      LinearGradient(
        colors: [Color(hex: 0x0071E3), Color(hex: 0x4B4FD9)], startPoint: .topLeading,
        endPoint: .bottomTrailing),
      in: .rect(cornerRadius: 16)
    )
    .shadow(color: Color(hex: 0x005AC8).opacity(0.25), radius: 10, y: 8)
  }
}

/// Row with a tinted icon, content and trailing controls; highlights on hover.
private struct MenuRow<Content: View, Trailing: View>: View {
  var symbol: String
  var color: Color
  var delay: Double
  @ViewBuilder var content: Content
  @ViewBuilder var trailing: Trailing
  @State private var hovered = false

  var body: some View {
    HStack(spacing: 10) {
      IconBadge(symbol: symbol, color: color, size: 28)
      content.frame(maxWidth: .infinity, alignment: .leading)
      trailing
    }
    .padding(8)
    .background(
      Color.sectorAccent.opacity(hovered ? 0.1 : 0), in: .rect(cornerRadius: 12)
    )
    .onHover { hovering in
      withAnimation(Motion.resolve(Motion.quick)) { hovered = hovering }
    }
    .appearAnimation(delay: delay, offset: 8)
  }
}

/// White capsule on the gradient card, with a periodic shimmer.
private struct WhitePillButtonStyle: ButtonStyle {
  var shimmer: Bool

  func makeBody(configuration: Configuration) -> some View {
    PillBody(configuration: configuration, shimmer: shimmer)
  }

  private struct PillBody: View {
    let configuration: Configuration
    var shimmer: Bool
    @State private var hovered = false

    var body: some View {
      configuration.label
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(Color(hex: 0x0062C4))
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Color.white.opacity(hovered ? 0.98 : 0.92), in: .capsule)
        .overlay {
          if shimmer && !Motion.reduced {
            ShimmerSweep().clipShape(.capsule).allowsHitTesting(false)
          }
        }
        .scaleEffect(configuration.isPressed ? 0.95 : 1)
        .animation(Motion.resolve(Motion.quick), value: configuration.isPressed)
        .onHover { hovered = $0 }
    }
  }
}

/// A soft highlight passing across the button every 2.8 s.
private struct ShimmerSweep: View {
  var body: some View {
    GeometryReader { geo in
      LinearGradient(
        colors: [
          Color(hex: 0x0071E3, opacity: 0), Color(hex: 0x0071E3, opacity: 0.2),
          Color(hex: 0x0071E3, opacity: 0),
        ], startPoint: .leading, endPoint: .trailing
      )
      .frame(width: 24)
      .rotationEffect(.degrees(20))
      .keyframeAnimator(initialValue: -40.0, repeating: true) { content, x in
        content.offset(x: x)
      } keyframes: { _ in
        CubicKeyframe(geo.size.width + 40, duration: 1.54)
        LinearKeyframe(geo.size.width + 40, duration: 1.26)
      }
    }
  }
}

/// Small grey capsule: "Очистить", "Разобрать".
private struct MenuCapsuleButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 11, weight: .semibold))
      .padding(.horizontal, 10)
      .frame(height: 24)
      .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06), in: .capsule)
      .opacity(isEnabled ? 1 : 0.45)
      .scaleEffect(configuration.isPressed ? 0.95 : 1)
      .animation(Motion.resolve(Motion.quick), value: configuration.isPressed)
      .contentShape(.capsule)
  }
}

/// Plain button that shrinks a little while pressed.
private struct MenuPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.92 : 1)
      .animation(Motion.resolve(Motion.quick), value: configuration.isPressed)
  }
}

/// Full-width menu item with the accent hover fill.
private struct MenuHoverStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HoverBody(configuration: configuration)
  }

  private struct HoverBody: View {
    let configuration: Configuration
    @State private var hovered = false

    var body: some View {
      configuration.label
        .background(
          Color.sectorAccent.opacity(configuration.isPressed ? 0.16 : hovered ? 0.1 : 0),
          in: .rect(cornerRadius: 10)
        )
        .onHover { hovering in
          withAnimation(Motion.resolve(Motion.quick)) { hovered = hovering }
        }
    }
  }
}

/// Reports when the hosting menu bar panel is shown (becomes key). SwiftUI
/// keeps the panel's views alive between openings, so `onAppear` alone
/// doesn't fire reliably.
private struct PanelLifecycle: NSViewRepresentable {
  var onOpen: @MainActor () -> Void

  func makeNSView(context: Context) -> ObserverView {
    let view = ObserverView()
    view.onOpen = onOpen
    return view
  }

  func updateNSView(_ view: ObserverView, context: Context) {
    view.onOpen = onOpen
  }

  final class ObserverView: NSView {
    var onOpen: (@MainActor () -> Void)?
    private var token: NSObjectProtocol?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let token { NotificationCenter.default.removeObserver(token) }
      token = nil
      guard let window else { return }
      token = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.opened() }
      }
      if window.isKeyWindow { opened() }
    }

    /// Deferred out of AppKit layout so SwiftUI state isn't changed
    /// mid-update.
    private func opened() {
      Task { @MainActor [weak self] in self?.onOpen?() }
    }
  }
}
