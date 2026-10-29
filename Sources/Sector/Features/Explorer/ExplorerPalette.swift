import Foundation
import SectorCore
import SwiftUI

/// Colors of disk-map items: the node's category color, lightened with
/// depth and alternating between siblings, as in the mock's `c` / `l` tints.
struct ExplorerPalette: Sendable {
  var breakdown: CategoryBreakdown?

  /// Shades per category: index `min(level, 5) * 2 + parity`.
  private static let shades: [[Color]] = DiskCategory.allCases.map { category in
    (0..<12).map { i in
      let level = Double(i / 2)
      let parity = Double(i % 2)
      return category.color.mix(with: .white, by: min(0.62, level * 0.14 + parity * 0.07))
    }
  }

  static let other = Color(hex: 0x8E8E93).opacity(0.38)

  func category(_ node: NodeID) -> DiskCategory {
    guard let breakdown, Int(node) < breakdown.nodeCategories.count else { return .documents }
    return breakdown.category(of: node)
  }

  func color(_ node: NodeID, level: Int, parity: Int) -> Color {
    let raw = DiskCategory.allCases.firstIndex(of: category(node)) ?? 0
    return Self.shades[raw][min(5, max(0, level)) * 2 + (parity & 1)]
  }

  func base(_ node: NodeID) -> Color { category(node).color }
}

/// Text helpers shared by the inspector, the center label and Overview.
enum ExplorerFormat {
  /// "/Users/me/Movies" → "~/Movies".
  static func displayPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
  }

  /// "Сегодня, 11:42", "Вчера, 09:10", "3 мес. назад".
  static func modified(_ date: Date, now: Date = Date()) -> String {
    guard date.timeIntervalSince1970 > 0 else { return "—" }
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDateInToday(date) { return String(localized: "Сегодня, \(time)") }
    if calendar.isDateInYesterday(date) { return String(localized: "Вчера, \(time)") }
    if now.timeIntervalSince(date) < 365 * 86_400 {
      return date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
    return date.formatted(date: .abbreviated, time: .omitted)
  }

  /// "Папка · Разработка", "Приложение", "Файл MOV".
  static func kind(_ node: NodeID, tree: FileTree, category: DiskCategory) -> String {
    let flags = tree.flags(node)
    if flags.contains(.symlink) { return String(localized: "Ссылка") }
    if flags.contains(.package) {
      return tree.pathExtension(node) == "app"
        ? String(localized: "Приложение") : String(localized: "Пакет · \(category.title)")
    }
    if flags.contains(.directory) {
      if node == FileTree.root && tree.rootPath == "/" { return String(localized: "Диск") }
      if tree.path(node) == NSHomeDirectory() { return String(localized: "Папка пользователя") }
      return String(localized: "Папка · \(category.title)")
    }
    let ext = tree.pathExtension(node).uppercased()
    return ext.isEmpty ? String(localized: "Файл") : String(localized: "Файл \(ext)")
  }

  /// "37 %" with "<1 %" for tiny shares.
  static func percent(_ part: UInt64, of whole: UInt64) -> String {
    guard whole > 0 else { return "0%" }
    let value = Double(part) / Double(whole) * 100
    if value > 0 && value < 1 { return "<1%" }
    return "\(Int(value.rounded()))%"
  }

  /// "Прочее" label with its item count.
  static func otherName(_ count: Int) -> String {
    String(localized: "Прочее · \(Plural.format(count, "объект", "объекта", "объектов"))")
  }
}

/// Easing curves evaluated per segment inside the chart renderers.
enum ExplorerEase {
  /// Ease-out with overshoot, like cubic-bezier(.34, 1.3, .64, 1).
  static func backOut(_ t: Double) -> Double {
    let c1 = 1.4
    let c3 = c1 + 1
    let x = t - 1
    return 1 + c3 * x * x * x + c1 * x * x
  }

  static func clamp(_ t: Double) -> Double { min(1, max(0, t)) }

  /// Local 0…1 progress of an item that starts after `delay` and lasts
  /// `duration` within a global timeline at `time`.
  static func local(_ time: Double, delay: Double, duration: Double) -> Double {
    clamp((time - delay) / duration)
  }
}
