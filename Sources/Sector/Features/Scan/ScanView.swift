import SectorCore
import SwiftUI

/// Scan screen (design/mockups/Scan.dc.html): radar with the live counter,
/// current path, progress and stats while scanning; a summary with what can
/// be freed once it finishes.
struct ScanView: View {
  @Environment(AppModel.self) private var model

  @State private var sunburst: ScanSunburst?
  /// False for a few seconds after finishing, while Smart Clean starts its
  /// analysis, so "nothing to free" does not flash before the real number.
  @State private var analysisGraceOver = false

  enum Stage: Equatable { case scanning, finished, cancelled }

  private var stage: Stage {
    switch model.scanState {
    case .finished: .finished
    case .cancelled: .cancelled
    case .idle, .running, .paused: .scanning
    }
  }

  private var isHomeScope: Bool { model.settings.scanScope == .home }

  var body: some View {
    let stage = stage
    let progress = model.scanProgress
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      ScanRadar(
        fraction: fraction(progress),
        isRunning: model.scanState == .running,
        isFinished: stage == .finished,
        sunburst: sunburst?.version == model.treeVersion ? sunburst : nil,
        bytes: progress.bytes,
        caption: caption(stage, progress),
        captionColor: stage == .cancelled ? .secondary : .sectorAccent
      )
      .padding(.top, 6)

      ZStack(alignment: .top) {
        switch stage {
        case .scanning:
          ScanLiveStats(
            progress: progress, fraction: fraction(progress),
            isPaused: model.scanState == .paused
          )
          .transition(.opacity.combined(with: .offset(y: -8)))
        case .finished, .cancelled:
          summary(stage, progress)
            .transition(.opacity.combined(with: .offset(y: 14)))
        }
      }
      .frame(width: 560, height: 196, alignment: .top)
      .padding(.top, 22)
      Spacer(minLength: 16)
    }
    .padding(.horizontal, 40)
    .padding(.bottom, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(Motion.resolve(Motion.smooth), value: stage)
    .navigationTitle("Сканирование")
    .navigationSubtitle(subtitle)
    .toolbar {
      if stage == .scanning && model.isScanning {
        ToolbarItem(placement: .primaryAction) {
          if model.scanState == .paused {
            Button {
              model.resumeScan()
            } label: {
              Label("Продолжить", systemImage: "play.fill")
            }
            .labelStyle(.titleAndIcon)
          } else {
            Button {
              model.pauseScan()
            } label: {
              Label("Пауза", systemImage: "pause.fill")
            }
            .labelStyle(.titleAndIcon)
          }
        }
      }
    }
    .task(id: model.treeVersion) { await computeSunburst() }
    .task(id: stage) {
      analysisGraceOver = false
      guard stage == .finished else { return }
      try? await Task.sleep(for: .seconds(3))
      analysisGraceOver = true
    }
  }

  // MARK: - Values

  /// Share of the volume's used space seen so far; nil when the scan covers
  /// only the home folder (no meaningful total).
  private func fraction(_ progress: ScanProgress) -> Double? {
    guard !isHomeScope, let used = model.volume?.used, used > 0 else { return nil }
    switch model.scanState {
    case .finished: return 1
    default: return min(0.99, Double(progress.bytes) / Double(used))
    }
  }

  private func caption(_ stage: Stage, _ progress: ScanProgress) -> String {
    switch stage {
    case .finished: return String(localized: "Готово")
    case .cancelled: return String(localized: "Остановлено")
    case .scanning:
      if let fraction = fraction(progress) {
        return fraction.formatted(.percent.precision(.fractionLength(0)))
      }
      return Duration.seconds(progress.elapsed).formatted(.time(pattern: .minuteSecond))
    }
  }

  private var subtitle: String {
    guard let volume = model.volume else { return "" }
    if isHomeScope {
      return String(localized: "\(volume.name) · Папка пользователя")
    }
    var parts = [volume.name]
    if !volume.fileSystem.isEmpty { parts.append(volume.fileSystem) }
    parts.append(ByteFormat.string(volume.total))
    return parts.joined(separator: " · ")
  }

  private func computeSunburst() async {
    guard let tree = model.tree, let breakdown = model.breakdown else {
      sunburst = nil
      return
    }
    let version = model.treeVersion
    let result = await Task.detached(priority: .userInitiated) {
      ScanSunburst.compute(tree: tree, breakdown: breakdown, version: version)
    }.value
    guard !Task.isCancelled else { return }
    sunburst = result
  }

  // MARK: - Summary

  @ViewBuilder
  private func summary(_ stage: Stage, _ progress: ScanProgress) -> some View {
    VStack(spacing: 0) {
      if case .finished(let duration) = model.scanState {
        ScanStatusBadge(
          symbol: "checkmark", color: Color(hex: 0x34C759),
          textColor: Color(light: 0x1E7A35, dark: 0x30D158),
          text: Text("Сканирование завершено за \(Self.durationText(duration))"))
        reclaimHeadline
          .padding(.top, 14)
      } else {
        ScanStatusBadge(
          symbol: "pause.fill", color: .sectorWarningFill, textColor: .sectorWarning,
          text: Text("Сканирование остановлено"))
        Text("Результаты неполные")
          .font(.system(size: 22, weight: .bold))
          .tracking(-0.4)
          .padding(.top, 14)
      }

      Text(scannedSummary(progress))
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.top, 4)

      HStack(spacing: 10) {
        if stage == .cancelled && model.tree == nil {
          Button("Сканировать снова") { model.startScan() }
            .buttonStyle(.glassProminent)
            .tint(.sectorAccent)
        } else {
          Button("Сканировать снова") { model.startScan() }
            .buttonStyle(.glass)
          Button {
            model.showResults()
          } label: {
            HStack(spacing: 6) {
              Text("Показать результаты")
              Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
            }
            .fontWeight(.semibold)
          }
          .buttonStyle(.glassProminent)
          .tint(.sectorAccent)
          .keyboardShortcut(.defaultAction)
        }
      }
      .controlSize(.large)
      .padding(.top, 18)

      if progress.deniedDirectories > 0 {
        deniedHint(progress.deniedDirectories)
          .padding(.top, 14)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var reclaimHeadline: some View {
    let clean = model.smartClean
    let bytes = clean.reclaimableBytes
    let analyzing = bytes == 0 && (clean.isAnalyzing || !analysisGraceOver)
    return ZStack {
      if bytes > 0 {
        Text("Можно освободить \(ByteFormat.string(bytes))")
          .contentTransition(.numericText(value: Double(bytes)))
          .transition(.opacity.combined(with: .scale(scale: 0.96)))
      } else if analyzing {
        HStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text("Ищем, что можно освободить…")
            .foregroundStyle(.secondary)
        }
        .transition(.opacity)
      } else {
        Text("Лишнего почти нет")
          .transition(.opacity)
      }
    }
    .font(.system(size: 22, weight: .bold))
    .tracking(-0.4)
    .frame(height: 28)
    .animation(Motion.resolve(Motion.smooth), value: bytes)
    .animation(Motion.resolve(Motion.smooth), value: analyzing)
  }

  private func deniedHint(_ count: Int) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "lock")
        .font(.system(size: 11, weight: .semibold))
      Text(
        "Нет доступа к \(Plural.format(count, "папке", "папкам", "папкам")) — их размер не учтён."
      )
      if !model.hasFullDiskAccess {
        Button("Открыть Настройки") { model.openFullDiskAccessSettings() }
          .buttonStyle(.link)
      }
    }
    .font(.system(size: 12))
    .foregroundStyle(.secondary)
    .lineLimit(1)
  }

  private func scannedSummary(_ progress: ScanProgress) -> String {
    let files = Plural.format(progress.files, "файл", "файла", "файлов")
    let folders = Plural.format(progress.directories, "папка", "папки", "папок")
    let size = ByteFormat.string(progress.bytes)
    return String(localized: "\(files) и \(folders) · \(size)")
  }

  /// "38 секунд", "2 минуты 5 секунд".
  static func durationText(_ duration: TimeInterval) -> String {
    let total = max(1, Int(duration.rounded()))
    let minutes = total / 60
    let seconds = total % 60
    let sec = Plural.format(seconds, "секунду", "секунды", "секунд")
    guard minutes > 0 else { return sec }
    let min = Plural.format(minutes, "минуту", "минуты", "минут")
    return seconds == 0 ? min : "\(min) \(sec)"
  }
}

/// Path, progress bar and the three stat tiles shown while scanning.
private struct ScanLiveStats: View {
  var progress: ScanProgress
  var fraction: Double?
  var isPaused: Bool

  private static let home = NSHomeDirectory()

  var body: some View {
    VStack(spacing: 0) {
      Text(displayPath)
        .font(.sectorPath)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity)
        .frame(height: 18)

      ScanProgressBar(fraction: fraction, isRunning: !isPaused)
        .padding(.top, 12)

      HStack(spacing: 10) {
        ScanStatTile(title: "Файлов") {
          Text(progress.files.formatted())
        }
        ScanStatTile(title: "Папок") {
          Text(progress.directories.formatted())
        }
        ScanStatTile(title: "Скорость") {
          if let rate = filesPerSecond {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
              Text(rate.formatted())
              Text("\(Plural.word(rate, "файл", "файла", "файлов"))/с")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
          } else {
            Text(verbatim: "—")
          }
        }
      }
      .padding(.top, 18)
    }
  }

  private var displayPath: String {
    if isPaused { return String(localized: "status.paused") }
    let path = progress.currentPath
    if path.hasPrefix(Self.home) { return "~" + path.dropFirst(Self.home.count) }
    return path
  }

  private var filesPerSecond: Int? {
    guard !isPaused, progress.elapsed > 0.5, progress.files > 0 else { return nil }
    return Int(Double(progress.files) / progress.elapsed)
  }
}

/// One stat tile ("Файлов", "Папок", "Скорость").
private struct ScanStatTile<Value: View>: View {
  var title: LocalizedStringKey
  @ViewBuilder var value: Value

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      value
        .font(.system(size: 17, weight: .bold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.sectorCard, in: .rect(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    .accessibilityElement(children: .combine)
  }
}

/// Gradient progress bar with a moving highlight; indeterminate scans show
/// a highlight sliding along the empty track instead.
private struct ScanProgressBar: View {
  var fraction: Double?
  var isRunning: Bool

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(Color.sectorTrack)
        if let fraction {
          Capsule()
            .fill(
              LinearGradient(
                colors: [Color(hex: 0x0071E3), Color(hex: 0x5E5CE6)], startPoint: .leading,
                endPoint: .trailing)
            )
            .overlay {
              ScanSlidingHighlight(
                stripWidth: 80, period: 1.3, isRunning: isRunning,
                colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)])
            }
            .clipShape(.capsule)
            .frame(width: max(8, width * fraction))
            .animation(.linear(duration: 0.2), value: fraction)
        } else {
          ScanSlidingHighlight(
            stripWidth: width * 0.4, period: 1.4, isRunning: isRunning,
            colors: [
              Color(hex: 0x0071E3, opacity: 0), Color(hex: 0x0071E3),
              Color(hex: 0x0071E3, opacity: 0),
            ])
          .clipShape(.capsule)
        }
      }
    }
    .frame(height: 8)
    .accessibilityElement()
    .accessibilityLabel(Text("Прогресс сканирования"))
    .accessibilityValue(
      fraction.map { Text($0.formatted(.percent.precision(.fractionLength(0)))) }
        ?? Text("Идёт сканирование"))
  }
}

/// A gradient strip that slides left to right forever.
private struct ScanSlidingHighlight: View {
  var stripWidth: CGFloat
  var period: Double
  var isRunning: Bool
  var colors: [Color]
  @State private var start = Date()

  var body: some View {
    GeometryReader { geo in
      TimelineView(.animation(minimumInterval: nil, paused: !isRunning || Motion.reduced)) {
        context in
        let elapsed = context.date.timeIntervalSince(start)
        let p = elapsed.truncatingRemainder(dividingBy: period) / period
        let from = -stripWidth
        let to = geo.size.width + stripWidth * 0.5
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
          .frame(width: stripWidth, height: geo.size.height)
          .offset(x: from + (to - from) * p)
      }
    }
    .opacity(Motion.reduced ? 0 : 1)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Pill with a round icon: "Сканирование завершено за 38 секунд".
private struct ScanStatusBadge: View {
  var symbol: String
  var color: Color
  var textColor: Color
  var text: Text
  @State private var shown = false

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .font(.system(size: 10, weight: .heavy))
        .foregroundStyle(.white)
        .frame(width: 20, height: 20)
        .background(color, in: .circle)
      text
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(textColor)
    }
    .padding(.leading, 8)
    .padding(.trailing, 14)
    .padding(.vertical, 6)
    .background(color.opacity(0.14), in: .capsule)
    .scaleEffect(shown || Motion.reduced ? 1 : 0.6)
    .opacity(shown ? 1 : 0)
    .onAppear {
      withAnimation(Motion.resolve(Motion.bouncy).delay(Motion.reduced ? 0 : 0.1)) {
        shown = true
      }
    }
  }
}
