import SectorCore
import SwiftUI
import WidgetKit

// Desktop widgets from design/mockups/MenuBar.dc.html: free space on the
// startup disk and what Smart Clean can free. Data comes from the snapshot
// the app writes into the App Group container; free space is re-read live
// so it stays current between app launches.

@main
struct SectorWidgets: WidgetBundle {
  var body: some Widget {
    DiskWidget()
    CleanWidget()
  }
}

struct SectorEntry: TimelineEntry {
  var date: Date
  var snapshot: WidgetSnapshot
  var hasData: Bool
}

struct SectorProvider: TimelineProvider {
  func placeholder(in context: Context) -> SectorEntry {
    SectorEntry(date: Date(), snapshot: .preview, hasData: true)
  }

  func getSnapshot(in context: Context, completion: @escaping (SectorEntry) -> Void) {
    completion(context.isPreview ? placeholder(in: context) : current())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<SectorEntry>) -> Void) {
    let next = Date().addingTimeInterval(15 * 60)
    completion(Timeline(entries: [current()], policy: .after(next)))
  }

  private func current() -> SectorEntry {
    let saved = WidgetSnapshot.load()
    var snapshot =
      saved
      ?? WidgetSnapshot(
        volumeName: "Macintosh HD", total: 0, available: 0, reclaimable: 0, categories: [])
    if let volume = VolumeInfo.startup() {
      snapshot.volumeName = volume.name
      snapshot.total = volume.total
      snapshot.available = volume.available
    }
    return SectorEntry(date: Date(), snapshot: snapshot, hasData: saved != nil)
  }
}

private let smartCleanURL = URL(string: "sector://smart-clean")!

/// The app icon's gradient, used as a tiny badge in widget headers.
private struct AppBadge: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 4)
      .fill(
        LinearGradient(
          colors: [Color(hex: 0x5AC8FA), Color(hex: 0x0A84FF), Color(hex: 0x5E5CE6)],
          startPoint: .topLeading, endPoint: .bottomTrailing)
      )
      .frame(width: 14, height: 14)
  }
}

// MARK: - Disk

struct DiskWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "com.kewldan.sector.disk", provider: SectorProvider()) { entry in
      DiskWidgetView(entry: entry)
        .containerBackground(.background, for: .widget)
        .widgetURL(smartCleanURL)
    }
    .configurationDisplayName("Свободное место")
    .description("Сколько осталось на загрузочном диске.")
    .supportedFamilies([.systemSmall])
  }
}

struct DiskWidgetView: View {
  var entry: SectorEntry

  var body: some View {
    let s = entry.snapshot
    let used = s.usedFraction
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        AppBadge()
        Text(s.volumeName).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        Spacer(minLength: 0)
      }
      .foregroundStyle(.secondary)

      ZStack {
        Circle().stroke(Color.primary.opacity(0.08), lineWidth: 10)
        Circle()
          .trim(from: 0, to: max(0.001, used))
          .stroke(
            used > 0.9 ? Color(hex: 0xE5243B) : Color(hex: 0x0A84FF),
            style: StrokeStyle(lineWidth: 10, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))
        VStack(spacing: 0) {
          Text(ByteFormat.parts(s.available).number)
            .font(.system(size: 20, weight: .bold))
            .monospacedDigit()
            .minimumScaleFactor(0.6)
          Text("\(ByteFormat.parts(s.available).unit) своб.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
      }
      .padding(5)
      .frame(width: 86, height: 86)
      .padding(.top, 8)

      Spacer(minLength: 4)
      Text("Занято \(Int((used * 100).rounded()))%")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Smart Clean

struct CleanWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "com.kewldan.sector.clean", provider: SectorProvider()) { entry in
      CleanWidgetView(entry: entry)
        .containerBackground(.background, for: .widget)
        .widgetURL(smartCleanURL)
    }
    .configurationDisplayName("Умная очистка")
    .description("Сколько можно освободить и где.")
    .supportedFamilies([.systemMedium])
  }
}

struct CleanWidgetView: View {
  var entry: SectorEntry

  var body: some View {
    let s = entry.snapshot
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        AppBadge()
        Text(verbatim: "Sector").font(.system(size: 11, weight: .semibold))
        Spacer(minLength: 0)
        if entry.hasData {
          Text("обновлено \(s.date, style: .relative) назад")
            .font(.system(size: 11, weight: .medium))
        }
      }
      .foregroundStyle(.secondary)

      if entry.hasData {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(ByteFormat.string(s.reclaimable))
            .font(.system(size: 26, weight: .bold))
            .monospacedDigit()
          Text("можно освободить")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
        Spacer(minLength: 6)
        CategoryBars(categories: s.categories)
      } else {
        Spacer(minLength: 0)
        Text("Откройте Sector, чтобы просканировать диск.")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
    }
  }
}

/// Bars sized relative to the largest category, labels underneath.
struct CategoryBars: View {
  var categories: [WidgetSnapshot.Category]

  var body: some View {
    let top = Double(categories.map(\.bytes).max() ?? 1)
    VStack(spacing: 5) {
      HStack(alignment: .bottom, spacing: 7) {
        ForEach(categories) { c in
          RoundedRectangle(cornerRadius: 5)
            .fill(Self.color(c.kind))
            .frame(height: max(4, 56 * Double(c.bytes) / max(top, 1)))
            .frame(maxWidth: .infinity)
        }
      }
      .frame(height: 56, alignment: .bottom)
      HStack(spacing: 7) {
        ForEach(categories) { c in
          Text(c.title)
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
        }
      }
    }
  }

  /// Colors from the mock's widget bars.
  static func color(_ kind: String) -> Color {
    switch kind {
    case "xcode": return Color(hex: 0x5E5CE6)
    case "nodeModules": return Color(hex: 0x34C759)
    case "docker": return Color(hex: 0x0071E3)
    case "simulators": return Color(hex: 0x8E8E93)
    case "appCaches": return Color(hex: 0x30B0C7)
    case "trash": return Color(hex: 0xA2845E)
    case "logs": return Color(hex: 0xFF9500)
    default: return Color(hex: 0xAF52DE)
    }
  }
}

extension Color {
  init(hex: UInt32) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}

#Preview(as: .systemSmall) {
  DiskWidget()
} timeline: {
  SectorEntry(date: Date(), snapshot: .preview, hasData: true)
}

#Preview(as: .systemMedium) {
  CleanWidget()
} timeline: {
  SectorEntry(date: Date(), snapshot: .preview, hasData: true)
}
