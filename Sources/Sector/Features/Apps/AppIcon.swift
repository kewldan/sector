import AppKit
import SectorCore
import SwiftUI

/// Finder icons of app bundles, loaded off the main actor and cached.
@MainActor
final class AppIconCache {
  static let shared = AppIconCache()

  private var icons: [String: NSImage] = [:]
  private var pending: [String: Task<NSImage?, Never>] = [:]

  func cached(_ path: String) -> NSImage? { icons[path] }

  func icon(for path: String) async -> NSImage? {
    if let icon = icons[path] { return icon }
    if let task = pending[path] { return await task.value }
    let task = Task<NSImage?, Never> {
      await Task.detached(priority: .userInitiated) {
        IconBox(image: NSWorkspace.shared.icon(forFile: path))
      }.value.image
    }
    pending[path] = task
    let icon = await task.value
    pending[path] = nil
    icons[path] = icon
    return icon
  }

  private struct IconBox: @unchecked Sendable { var image: NSImage }
}

/// An app's real icon; a soft placeholder until it loads.
struct AppIconView: View {
  var url: URL
  var size: CGFloat

  @State private var image: NSImage?

  var body: some View {
    ZStack {
      if let image {
        Image(nsImage: image)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .transition(.opacity)
      } else {
        RoundedRectangle(cornerRadius: size * 0.225)
          .fill(Color.sectorTrack)
          .padding(size * 0.09)
      }
    }
    .frame(width: size, height: size)
    .task(id: url) {
      if let cached = AppIconCache.shared.cached(url.path) {
        image = cached
        return
      }
      let icon = await AppIconCache.shared.icon(for: url.path)
      withAnimation(Motion.resolve(Motion.quick)) { image = icon }
    }
    .accessibilityHidden(true)
  }
}

/// "Сегодня", "7 мес. назад", "Не открывали 1,5 года".
enum AppAge {
  static func months(_ date: Date?, now: Date = .now) -> Int? {
    guard let date else { return nil }
    return max(0, Calendar.current.dateComponents([.month], from: date, to: now).month ?? 0)
  }

  /// Unused for half a year or more (or never opened).
  static func isStale(_ date: Date?) -> Bool { (months(date) ?? .max) >= 6 }

  static func text(_ date: Date?, now: Date = .now) -> String {
    guard let date else { return String(localized: "Не открывали") }
    let calendar = Calendar.current
    let days = calendar.dateComponents(
      [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
    ).day ?? 0
    let months = self.months(date, now: now) ?? 0
    switch (days, months) {
    case (...0, _): return String(localized: "Сегодня")
    case (1, _): return String(localized: "Вчера")
    case (_, 0):
      return String(localized: "\(Plural.format(days, "день", "дня", "дней")) назад")
    case (_, ..<12): return String(localized: "\(months) мес. назад")
    case (_, ..<18): return String(localized: "1 год назад")
    default:
      let halves = months / 6
      if halves % 2 == 0 {
        let years = Plural.format(halves / 2, "год", "года", "лет")
        return String(localized: "Не открывали \(years)")
      }
      let years = (Double(halves) / 2).formatted(.number.precision(.fractionLength(1)))
      return String(localized: "Не открывали \(years) года")
    }
  }

  static func color(_ date: Date?) -> Color {
    let months = months(date) ?? .max
    if months >= 12 { return .sectorWarning }
    if months >= 6 { return .primary.opacity(0.8) }
    return .secondary
  }
}
