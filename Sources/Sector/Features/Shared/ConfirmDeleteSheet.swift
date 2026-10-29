import SectorCore
import SwiftUI

/// Confirmation sheet for every deletion (design/mockups/ConfirmDelete.dc.html).
/// Shown by `MainView` whenever `AppModel.deletionRequest` is set.
struct ConfirmDeleteSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let request: DeletionRequest

  /// nil until the user picks; falls back to the "move to Trash" setting.
  @State private var pickedMode: RemovalMode?
  @State private var skipDownloads = false
  @State private var isPerforming = false

  private var mode: RemovalMode {
    pickedMode ?? (model.settings.moveToTrash ? .trash : .permanent)
  }
  private var isPermanent: Bool { mode == .permanent }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      itemList.padding(.top, 18)
      options.padding(.top, 14)
      if isPermanent {
        PermanentWarning()
          .padding(.top, 10)
          .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
      }
      if request.isInDownloads {
        Toggle("Больше не спрашивать для файлов из «Загрузок»", isOn: $skipDownloads)
          .toggleStyle(.checkbox)
          .font(.system(size: 12))
          .padding(.top, 14)
      }
      buttons.padding(.top, 18)
    }
    .padding(.horizontal, 24)
    .padding(.top, 24)
    .padding(.bottom, 20)
    .frame(width: 480)
    .animation(Motion.resolve(Motion.smooth), value: isPermanent)
    .interactiveDismissDisabled(isPerforming)
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .top, spacing: 16) {
      TrashDropIcon(
        permanent: isPermanent,
        dropColors: request.items.prefix(3).map { FileKindStyle.color(for: $0.url) })
      VStack(alignment: .leading, spacing: 6) {
        Text(title)
          .font(.system(size: 17, weight: .bold))
          .fixedSize(horizontal: false, vertical: true)
          .contentTransition(.opacity)
        Text(subtitle)
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .contentTransition(.opacity)
      }
      .padding(.top, 2)
    }
  }

  private var title: String {
    let items = request.items
    if items.count == 1, let item = items.first {
      return isPermanent
        ? String(localized: "Удалить «\(item.name)» навсегда?")
        : String(localized: "Переместить «\(item.name)» в Корзину?")
    }
    let allFiles = items.allSatisfy { !$0.url.hasDirectoryPath }
    let counted =
      allFiles
      ? Plural.format(items.count, "файл", "файла", "файлов")
      : Plural.format(items.count, "объект", "объекта", "объектов")
    return isPermanent
      ? String(localized: "Удалить \(counted) навсегда?")
      : String(localized: "Переместить \(counted) в Корзину?")
  }

  private var subtitle: String {
    let size = ByteFormat.string(request.totalSize)
    return isPermanent
      ? String(localized: "Будет освобождено \(size) прямо сейчас. Это действие нельзя отменить.")
      : String(
        localized:
          "Освободится \(size) после очистки Корзины. До этого всё можно вернуть из «Истории».")
  }

  // MARK: - Items

  private static let visibleRows = 5
  private static let rowHeight: CGFloat = 40

  @ViewBuilder private var itemList: some View {
    let rows = LazyVStack(spacing: 0) {
      ForEach(Array(request.items.enumerated()), id: \.element.id) { index, item in
        VStack(spacing: 0) {
          if index > 0 {
            Rectangle().fill(Color.sectorHairline).frame(height: 0.5).padding(.horizontal, 10)
          }
          HStack(spacing: 10) {
            FileKindBadge(
              label: item.kindLabel, color: FileKindStyle.color(for: item.url), size: 24)
            Text(item.name)
              .lineLimit(1)
              .truncationMode(.middle)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(ByteFormat.string(item.size))
              .fontWeight(.semibold)
              .monospacedDigit()
          }
          .font(.system(size: 13))
          .padding(.horizontal, 10)
          .frame(height: Self.rowHeight - 0.5)
          .help(item.url.path)
        }
        .appearAnimation(
          delay: index <= Self.visibleRows ? Motion.stagger(index, step: 0.07, base: 0.3) : 0,
          offset: 10)
      }
    }
    .padding(4)

    Group {
      if request.items.count > Self.visibleRows {
        ScrollView { rows }
          .frame(height: CGFloat(Self.visibleRows) * Self.rowHeight + 28)
      } else {
        rows
      }
    }
    .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 14))
    .overlay(
      RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
  }

  // MARK: - Options

  private var options: some View {
    HStack(spacing: 8) {
      OptionCard(
        symbol: "arrow.uturn.backward", title: "В Корзину",
        subtitle: String(
          localized:
            "Можно вернуть в течение \(Plural.format(model.settings.keepDays, "дня", "дней", "дней"))"
        ),
        isSelected: !isPermanent, tint: .sectorAccent, selectedText: .sectorAccentPressed
      ) { pick(.trash) }
      OptionCard(
        symbol: "exclamationmark.triangle", title: "Удалить сразу",
        subtitle: String(localized: "Место освободится мгновенно"),
        isSelected: isPermanent, tint: .sectorDanger, selectedText: .sectorDangerText
      ) { pick(.permanent) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Способ удаления"))
    .disabled(isPerforming)
  }

  private func pick(_ mode: RemovalMode) {
    withAnimation(Motion.resolve(Motion.bouncy)) { pickedMode = mode }
  }

  // MARK: - Buttons

  private var buttons: some View {
    HStack(spacing: 10) {
      if isPerforming {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(isPermanent ? "Удаляю…" : "Перемещаю в Корзину…")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .transition(.opacity)
      }
      Spacer(minLength: 0)
      Button("Отменить") { dismiss() }
        .buttonStyle(.glass)
        .keyboardShortcut(.cancelAction)
      if isPermanent {
        Button("Удалить навсегда", action: confirm)
          .buttonStyle(.glassProminent)
          .tint(.sectorDanger)
          .background { if !isPerforming { DangerPulse() } }
          .transition(.opacity)
      } else {
        Button("Переместить в Корзину", action: confirm)
          .buttonStyle(.glassProminent)
          .tint(.sectorAccent)
          .keyboardShortcut(.defaultAction)
          .transition(.opacity)
      }
    }
    .controlSize(.large)
    .disabled(isPerforming)
    .animation(Motion.resolve(Motion.quick), value: isPerforming)
  }

  private func confirm() {
    guard !isPerforming else { return }
    if skipDownloads { model.settings.skipConfirmForDownloads = true }
    isPerforming = true
    let mode = mode
    Task {
      await model.perform(request, mode: mode)
      dismiss()
    }
  }
}

// MARK: - Downloads

extension DeletionRequest {
  /// Whether every item lies inside the user's Downloads folder; such
  /// deletions may skip the sheet (`AppSettings.skipConfirmForDownloads`).
  var isInDownloads: Bool {
    guard
      !items.isEmpty,
      let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    else { return false }
    let root = downloads.standardizedFileURL.path
    let prefix = root.hasSuffix("/") ? root : root + "/"
    return items.allSatisfy { $0.url.standardizedFileURL.path.hasPrefix(prefix) }
  }
}

// MARK: - File kinds

/// Tint for file-type badges, shared by file lists and this sheet.
enum FileKindStyle {
  static func color(for url: URL) -> Color {
    if url.hasDirectoryPath && url.pathExtension.isEmpty { return Color(hex: 0x0A84FF) }
    return color(forExtension: url.pathExtension)
  }

  static func color(forExtension ext: String) -> Color {
    switch ext.lowercased() {
    case "pvm", "pvmp", "hdd":
      return Color(hex: 0x4A48C9)
    case "raw", "vmdk", "vdi", "qcow2", "utm", "vhd", "vhdx", "vmwarevm", "img":
      return Color(hex: 0x5E5CE6)
    case "mov", "mp4", "m4v", "mkv", "avi", "webm", "mts", "braw", "r3d", "fcpbundle", "prproj",
      "aep":
      return Color(hex: 0xAF52DE)
    case "jpg", "jpeg", "png", "heic", "tif", "tiff", "psd", "cr2", "cr3", "nef", "arw", "dng",
      "mp3", "m4a", "wav", "aif", "aiff", "flac", "logicx", "band":
      return Color(hex: 0xFF2D55)
    case "bak", "backup", "sql", "dump", "db", "sqlite", "mdbackup", "sparsebundle":
      return Color(hex: 0x1E9BB3)
    case "zip", "xip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst", "lz4":
      return Color(hex: 0xE08600)
    case "dmg", "iso", "ipsw", "pkg", "sparseimage", "toast", "app":
      return Color(hex: 0x7C7C82)
    case "pdf", "key", "pages", "numbers", "docx", "xlsx", "pptx":
      return Color(hex: 0xFF9500)
    case "log", "txt", "csv", "json", "jsonl", "ndjson", "parquet", "bin", "dat", "safetensors",
      "gguf", "ckpt", "pt", "onnx":
      return Color(hex: 0x34A853)
    default:
      return Color(hex: 0x8E8E93)
    }
  }
}

extension Color {
  /// Text on a selected danger control.
  fileprivate static let sectorDangerText = Color(light: 0xB0121F, dark: 0xFF6961)
  fileprivate static let sectorDangerDeep = Color(light: 0xB0121F, dark: 0xD70015)
}

// MARK: - Pieces

/// Selectable card for "В Корзину" / "Удалить сразу".
private struct OptionCard: View {
  var symbol: String
  var title: LocalizedStringKey
  var subtitle: String
  var isSelected: Bool
  var tint: Color
  var selectedText: Color
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 3) {
        Label(title, systemImage: symbol)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(isSelected ? selectedText : Color.primary)
        Text(subtitle)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 11)
      .background(
        isSelected ? tint.opacity(0.08) : Color.sectorCard, in: .rect(cornerRadius: 14)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14)
          .strokeBorder(
            isSelected ? tint : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
      )
      .contentShape(.rect(cornerRadius: 14))
    }
    .buttonStyle(PressScaleStyle())
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}

private struct PressScaleStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .animation(Motion.resolve(Motion.bouncy), value: configuration.isPressed)
  }
}

/// "Файлы нельзя будет восстановить" banner; shakes once when it appears.
private struct PermanentWarning: View {
  @State private var shakes = 0

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.circle")
        .font(.system(size: 14, weight: .semibold))
      Text("Файлы нельзя будет восстановить — даже через Sector.")
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.system(size: 12))
    .foregroundStyle(Color.sectorDangerText)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(Color.sectorDanger.opacity(0.09), in: .rect(cornerRadius: 12))
    .keyframeAnimator(initialValue: CGFloat(0), trigger: shakes) { content, x in
      content.offset(x: x)
    } keyframes: { _ in
      KeyframeTrack {
        CubicKeyframe(-6, duration: 0.1)
        CubicKeyframe(5, duration: 0.1)
        CubicKeyframe(-3, duration: 0.1)
        CubicKeyframe(2, duration: 0.1)
        CubicKeyframe(0, duration: 0.1)
      }
    }
    .onAppear { if !Motion.reduced { shakes += 1 } }
    .accessibilityAddTraits(.isStaticText)
  }
}

/// Expanding red ring behind "Удалить навсегда".
private struct DangerPulse: View {
  var body: some View {
    if !Motion.reduced {
      Capsule()
        .fill(Color.sectorDanger)
        .keyframeAnimator(initialValue: CGFloat(0), repeating: true) { content, p in
          content
            .padding(-12 * p)
            .opacity(0.4 * (1 - p))
        } keyframes: { _ in
          KeyframeTrack {
            LinearKeyframe(0, duration: 0.3)
            CubicKeyframe(1, duration: 1.4)
          }
        }
        .allowsHitTesting(false)
    }
  }
}

/// Trash can whose lid opens while three files drop in, on a 3.2 s loop.
private struct TrashDropIcon: View {
  var permanent: Bool
  var dropColors: [Color]

  private static let period = 3.2

  var body: some View {
    let reduced = Motion.reduced
    TimelineView(.animation(minimumInterval: nil, paused: reduced)) { context in
      let t =
        reduced
        ? 0
        : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
          / Self.period
      canvas(t: t)
    }
    .frame(width: 64, height: 64)
    .background(
      permanent ? Color.sectorDanger.opacity(0.12) : Color.sectorAccent.opacity(0.1),
      in: .rect(cornerRadius: 18)
    )
    .animation(Motion.resolve(.easeInOut(duration: 0.3)), value: permanent)
    .accessibilityHidden(true)
  }

  private func canvas(t: Double) -> some View {
    let canColor = permanent ? Color.sectorDanger : Color.sectorAccent
    let lidColor = permanent ? Color.sectorDangerDeep : Color.sectorAccentPressed
    let fallback: [Color] = [Color(hex: 0x5E5CE6), Color(hex: 0x1E9BB3), Color(hex: 0x8E8E93)]
    let colors = (0..<3).map { $0 < dropColors.count ? dropColors[$0] : fallback[$0] }
    return Canvas { ctx, size in
      // The drawing is authored in a 44×48 box centred in the badge.
      ctx.translateBy(x: (size.width - 44) / 2, y: (size.height - 48) / 2)

      for (i, drop) in Self.drops.enumerated() {
        var c = ctx
        c.opacity = Self.value(t, drop.opacity)
        guard c.opacity > 0.001 else { continue }
        c.translateBy(x: Self.value(t, drop.x) + 22, y: Self.value(t, drop.y) + 20)
        c.rotate(by: .degrees(Self.value(t, drop.angle)))
        c.translateBy(x: -22, y: -20)
        c.fill(
          Path(roundedRect: CGRect(x: 17, y: 14, width: 10, height: 12), cornerRadius: 2),
          with: .color(colors[i]))
      }

      var can = ctx
      can.translateBy(x: 22, y: 46)
      can.scaleBy(x: Self.value(t, Self.bumpX), y: Self.value(t, Self.bumpY))
      can.translateBy(x: -22, y: -46)
      can.fill(Self.canPath, with: .color(canColor))
      can.stroke(
        Self.stripes, with: .color(.white.opacity(0.55)),
        style: StrokeStyle(lineWidth: 2, lineCap: .round))

      var lid = ctx
      lid.translateBy(x: 7, y: 17)
      lid.rotate(by: .degrees(Self.value(t, Self.lidAngle)))
      lid.translateBy(x: -7, y: -17)
      lid.fill(
        Path(roundedRect: CGRect(x: 6, y: 13, width: 32, height: 5), cornerRadius: 2.5),
        with: .color(lidColor))
      lid.fill(
        Path(roundedRect: CGRect(x: 18, y: 9.5, width: 8, height: 4), cornerRadius: 1.5),
        with: .color(lidColor))
    }
  }

  // Keyframes from the mock's CSS (`drop1…3`, `lid`, `canBump`), as
  // (progress, value) pairs over one period.
  private typealias Track = [(Double, Double)]

  private struct Drop {
    var x: Track
    var y: Track
    var angle: Track
    var opacity: Track
  }

  private static func drop(start: Double, from: (Double, Double, Double), land: Double)
    -> Drop
  {
    let visible = start + 0.08
    let settle = land + 0.08
    return Drop(
      x: [(0, from.0), (start, from.0), (land, 0), (1, 0)],
      y: [(0, from.1), (start, from.1), (land, 6), (settle, 12), (1, 12)],
      angle: [(0, from.2), (start, from.2), (land, 0), (1, 0)],
      opacity: [(0, 0), (start, 0), (visible, 1), (land, 1), (settle, 0), (1, 0)])
  }

  private static let drops: [Drop] = [
    drop(start: 0.22, from: (-18, -40, -20), land: 0.52),
    drop(start: 0.30, from: (16, -44, 18), land: 0.60),
    drop(start: 0.38, from: (0, -50, 8), land: 0.66),
  ]
  private static let lidAngle: Track = [
    (0, 0), (0.18, 0), (0.30, -28), (0.70, -28), (0.82, 0), (1, 0),
  ]
  private static let bumpX: Track = [
    (0, 1), (0.50, 1), (0.56, 1.06), (0.62, 0.98), (0.70, 1), (1, 1),
  ]
  private static let bumpY: Track = [
    (0, 1), (0.50, 1), (0.56, 0.95), (0.62, 1.02), (0.70, 1), (1, 1),
  ]

  /// Smoothstep interpolation between keyframes.
  private static func value(_ t: Double, _ track: Track) -> Double {
    guard var previous = track.first else { return 0 }
    if t <= previous.0 { return previous.1 }
    for frame in track.dropFirst() {
      if t <= frame.0 {
        let span = frame.0 - previous.0
        let p = span > 0 ? (t - previous.0) / span : 1
        let eased = p * p * (3 - 2 * p)
        return previous.1 + (frame.1 - previous.1) * eased
      }
      previous = frame
    }
    return previous.1
  }

  private static let canPath: Path = {
    var p = Path()
    p.move(to: CGPoint(x: 9, y: 20))
    p.addLine(to: CGPoint(x: 35, y: 20))
    p.addLine(to: CGPoint(x: 32.8, y: 44))
    p.addQuadCurve(to: CGPoint(x: 29.8, y: 46.7), control: CGPoint(x: 32.6, y: 46.7))
    p.addLine(to: CGPoint(x: 14.2, y: 46.7))
    p.addQuadCurve(to: CGPoint(x: 11.2, y: 44), control: CGPoint(x: 11.4, y: 46.7))
    p.closeSubpath()
    return p
  }()

  private static let stripes: Path = {
    var p = Path()
    for x in [17.0, 22.0, 27.0] {
      p.move(to: CGPoint(x: x, y: 26))
      p.addLine(to: CGPoint(x: x, y: 40))
    }
    return p
  }()
}
