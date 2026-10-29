import SectorCore
import SwiftUI

/// Banners at the top of Overview (design/mockups/States.dc.html): critical
/// low space and folders the scan could not read. Shows nothing when all is
/// fine; banners slide in and out as the state changes.
struct DiskStatusBanner: View {
  @Environment(AppModel.self) private var model
  @AppStorage("banner.access.dismissed") private var accessDismissed = false

  var body: some View {
    let critical = criticalVolume
    let denied = deniedFolders
    VStack(spacing: Metrics.gap) {
      if let critical {
        CriticalSpaceBanner(volume: critical, reclaimable: model.smartClean.reclaimableBytes)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
      if !denied.isEmpty {
        NoAccessBanner(folders: denied, hiddenBytes: model.unscannedBytes) {
          withAnimation(Motion.resolve(Motion.smooth)) { accessDismissed = true }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(Motion.resolve(Motion.smooth), value: critical != nil)
    .animation(Motion.resolve(Motion.smooth), value: denied.isEmpty)
  }

  /// The startup volume when free space is under the warning threshold or
  /// below 5 % of the disk.
  private var criticalVolume: VolumeInfo? {
    guard let volume = model.volume, volume.total > 0 else { return nil }
    let threshold = AppModel.bytes(gigabytes: model.settings.lowSpaceThresholdGB)
    let low = volume.available < threshold || Double(volume.available) < Double(volume.total) * 0.05
    return low ? volume : nil
  }

  /// Top-most denied folders (children of another denied folder dropped).
  private var deniedFolders: [String] {
    guard !accessDismissed, !model.hasFullDiskAccess, !model.deniedPaths.isEmpty else { return [] }
    var tops: [String] = []
    for path in model.deniedPaths.sorted() where !tops.contains(where: { path.hasPrefix($0 + "/") }) {
      tops.append(path)
    }
    return tops
  }
}

// MARK: - Critical space

private struct CriticalSpaceBanner: View {
  @Environment(AppModel.self) private var model
  var volume: VolumeInfo
  var reclaimable: UInt64

  @State private var filled: Double = 0
  @State private var pulse = false

  var body: some View {
    Card(padding: 24) {
      HStack(spacing: 24) {
        ring
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 6) {
            Image(systemName: "bell.fill")
              .font(.system(size: 10, weight: .bold))
              .symbolEffect(.wiggle, options: .repeat(.periodic(delay: 1.6)), isActive: !Motion.reduced)
            Text("Критически мало места")
              .font(.system(size: 11, weight: .bold))
          }
          .foregroundStyle(Color.sectorDanger)
          .padding(.horizontal, 10)
          .padding(.vertical, 3)
          .background(Color.sectorDanger.opacity(0.1), in: .rect(cornerRadius: 10))

          Text("Свободно всего \(ByteFormat.string(volume.available))")
            .font(.system(size: 20, weight: .bold))
            .monospacedDigit()
            .contentTransition(.numericText())
            .padding(.top, 10)
          Text(message)
            .font(.sectorBody)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)

          HStack(spacing: 8) {
            Button("Быстрая очистка") { model.startQuickClean() }
              .buttonStyle(.glassProminent)
              .tint(Color.sectorDanger)
            Button("Выбрать вручную") { model.presentInMainWindow(.smartClean) }
              .buttonStyle(.glass)
          }
          .controlSize(.large)
          .padding(.top, 16)
        }
        Spacer(minLength: 0)
      }
    }
    .onAppear {
      withAnimation(stagedAnimation(.spring(duration: 1.6, bounce: 0), delay: 0.4)) {
        filled = volume.usedFraction
      }
      guard !Motion.reduced else { return }
      withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
    }
    .onChange(of: volume.usedFraction) { _, new in
      withAnimation(Motion.resolve(Motion.smooth)) { filled = new }
    }
  }

  private var message: String {
    let base = String(
      localized: "macOS может работать медленнее, а обновления — не установиться.")
    guard reclaimable > 0 else { return base }
    return base + " "
      + String(localized: "Безопасная очистка освободит \(ByteFormat.string(reclaimable)).")
  }

  private var ring: some View {
    let size: CGFloat = 116
    return ZStack {
      // Expanding red halo, like the mock's critPulse.
      Circle()
        .stroke(Color.sectorDanger.opacity(0.45), lineWidth: 8)
        .padding(4)
        .scaleEffect(pulse ? 1.24 : 1)
        .opacity(pulse ? 0 : 1)
      ProgressRing(fraction: filled, lineWidth: 13, color: .sectorDanger)
      VStack(spacing: 0) {
        Text("\(Int((volume.usedFraction * 100).rounded()))%")
          .font(.system(size: 24, weight: .heavy))
          .monospacedDigit()
          .foregroundStyle(Color.sectorDanger)
        Text("занято")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - No access

private struct NoAccessBanner: View {
  @Environment(AppModel.self) private var model
  var folders: [String]
  var hiddenBytes: UInt64
  var skip: () -> Void

  var body: some View {
    Card(padding: 24) {
      HStack(alignment: .center, spacing: 20) {
        Image(systemName: "lock.fill")
          .font(.system(size: 26, weight: .semibold))
          .foregroundStyle(.white)
          .symbolEffect(.wiggle, options: .repeat(.periodic(delay: 2)), isActive: !Motion.reduced)
          .frame(width: 60, height: 60)
          .background(
            LinearGradient(
              colors: [Color(hex: 0xFFB340), Color(hex: 0xFF9500)], startPoint: .top,
              endPoint: .bottom),
            in: .rect(cornerRadius: 18)
          )
          .shadow(color: Color(hex: 0xFF9500).opacity(0.35), radius: 12, y: 8)

        VStack(alignment: .leading, spacing: 4) {
          Text("Нет доступа к \(Plural.format(folders.count, "папке", "папкам", "папкам"))")
            .font(.system(size: 17, weight: .bold))
          Text(pathsLine)
            .font(.sectorPath)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
          Text(message)
            .font(.sectorBody)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 12)
        HStack(spacing: 8) {
          Button("Пропустить", action: skip)
            .buttonStyle(.glass)
          Button("Выдать доступ") { model.openFullDiskAccessSettings() }
            .buttonStyle(.glassProminent)
        }
        .controlSize(.large)
      }
    }
  }

  private var pathsLine: String {
    let shown = folders.prefix(3).map { ($0 as NSString).abbreviatingWithTildeInPath }
    let rest = folders.count - shown.count
    let line = shown.joined(separator: " · ")
    return rest > 0 ? line + " " + String(localized: "и ещё \(rest)") : line
  }

  private var message: String {
    if hiddenBytes >= AppModel.bytes(gigabytes: 1) {
      return String(
        localized:
          "Из-за этого Sector не видит примерно \(ByteFormat.string(hiddenBytes)). Включите полный доступ к диску.")
    }
    return String(localized: "Включите полный доступ к диску, чтобы Sector видел все файлы.")
  }
}
