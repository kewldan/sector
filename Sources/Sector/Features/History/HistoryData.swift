import Foundation
import SectorCore
import SwiftUI

/// What is in ~/.Trash right now.
struct TrashSnapshot: Sendable {
  /// False when macOS denied reading the Trash (no Full Disk Access).
  var accessible: Bool
  var size: UInt64
  /// Top-level entries, ready for `FileRemover`.
  var items: [RemovalItem]
  /// Entries the user would recognise (without .DS_Store).
  var visibleCount: Int

  static let trashURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    .appendingPathComponent(".Trash", isDirectory: true)

  /// Walks the Trash; call off the main actor.
  static func measure() -> TrashSnapshot {
    let fm = FileManager()
    let keys: [URLResourceKey] = [
      .isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
    ]
    guard
      let entries = try? fm.contentsOfDirectory(
        at: trashURL, includingPropertiesForKeys: keys, options: [])
    else {
      return TrashSnapshot(accessible: false, size: 0, items: [], visibleCount: 0)
    }
    var items: [RemovalItem] = []
    var total: UInt64 = 0
    var visible = 0
    for entry in entries {
      let size = allocatedSize(entry, keys: keys, fm: fm)
      total &+= size
      items.append(RemovalItem(url: entry, size: size))
      if entry.lastPathComponent != ".DS_Store" { visible += 1 }
    }
    items.sort { $0.size > $1.size }
    return TrashSnapshot(accessible: true, size: total, items: items, visibleCount: visible)
  }

  private static func allocatedSize(_ url: URL, keys: [URLResourceKey], fm: FileManager)
    -> UInt64
  {
    let keySet = Set(keys)
    func size(_ values: URLResourceValues?) -> UInt64 {
      UInt64(max(0, values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0))
    }
    let values = try? url.resourceValues(forKeys: keySet)
    guard values?.isDirectory == true, values?.isSymbolicLink != true else { return size(values) }
    var total: UInt64 = 0
    guard
      let enumerator = fm.enumerator(
        at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
    else { return 0 }
    while let child = enumerator.nextObject() as? URL {
      total &+= size(try? child.resourceValues(forKeys: keySet))
    }
    return total
  }
}

/// Per-record state that needs the file system, computed off-main.
struct HistoryStatus: Sendable {
  /// Records with at least one item still waiting in the Trash.
  var restorable: Set<UUID> = []
  /// Bytes of those items.
  var restorableBytes: UInt64 = 0

  static func compute(_ records: [CleanupRecord]) -> HistoryStatus {
    var status = HistoryStatus()
    for record in records where record.mode == .trash {
      var any = false
      for item in record.items where !record.restoredPaths.contains(item.originalPath) {
        if FileRemover.canRestore(item) {
          any = true
          status.restorableBytes &+= item.size
        }
      }
      if any { status.restorable.insert(record.id) }
    }
    return status
  }
}

/// One bar of "Освобождено за полгода".
struct MonthBar: Identifiable, Sendable {
  var id: Date { start }
  let start: Date
  let label: String
  let bytes: UInt64
  let isCurrent: Bool
}

extension CleanupRecord {
  /// Bytes still freed: items moved back from the Trash no longer count.
  var netFreedBytes: UInt64 {
    items.reduce(UInt64(0)) { restoredPaths.contains($1.originalPath) ? $0 : $0 + $1.size }
  }

  var restoredBytes: UInt64 {
    items.reduce(UInt64(0)) { restoredPaths.contains($1.originalPath) ? $0 + $1.size : $0 }
  }
}

@MainActor
enum HistoryFormat {
  /// The last six calendar months, oldest first, with net freed bytes.
  static func months(_ records: [CleanupRecord], now: Date = Date()) -> [MonthBar] {
    let calendar = Calendar.current
    guard let current = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
    else { return [] }
    return (0..<6).compactMap { k -> MonthBar? in
      guard
        let start = calendar.date(byAdding: .month, value: k - 5, to: current),
        let end = calendar.date(byAdding: .month, value: 1, to: start)
      else { return nil }
      let bytes = records.lazy.filter { $0.date >= start && $0.date < end }
        .reduce(UInt64(0)) { $0 + $1.netFreedBytes }
      return MonthBar(start: start, label: monthLabel(start), bytes: bytes, isCurrent: k == 5)
    }
  }

  private static let monthFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = .current
    f.dateFormat = "LLL"
    return f
  }()

  /// "Май", "Авг.", "Окт."
  static func monthLabel(_ date: Date) -> String {
    let text = monthFormatter.string(from: date)
    return text.prefix(1).uppercased() + text.dropFirst()
  }

  /// "Только что", "5 мин. назад", "Сегодня, 14:02", "Вчера, 09:10", "12 окт.".
  static func when(_ date: Date, now: Date = Date()) -> String {
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return String(localized: "Только что") }
    if seconds < 3600 {
      let minutes = Int(seconds / 60)
      return String(localized: "\(minutes) мин. назад")
    }
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDateInToday(date) { return String(localized: "Сегодня, \(time)") }
    if calendar.isDateInYesterday(date) { return String(localized: "Вчера, \(time)") }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
      return date.formatted(.dateTime.day().month(.abbreviated))
    }
    return date.formatted(.dateTime.day().month(.abbreviated).year())
  }

  /// Row title: the stored title, with a count for file-based sources.
  static func title(_ record: CleanupRecord) -> String {
    switch record.source {
    case .smartClean, .apps:
      return record.title
    case .files, .duplicates, .explorer, .trash:
      let count = Plural.format(record.items.count, "объект", "объекта", "объектов")
      return "\(record.title) · \(count)"
    }
  }

  /// Row detail: names of what was removed for file-based sources.
  static func detail(_ record: CleanupRecord) -> String {
    switch record.source {
    case .smartClean, .apps:
      return record.detail
    case .files, .duplicates, .explorer, .trash:
      let names = record.items.prefix(8).map {
        ($0.originalPath as NSString).lastPathComponent
      }
      let more = record.items.count - names.count
      let list = names.joined(separator: ", ")
      return more > 0 ? String(localized: "\(list) и ещё \(more)") : list
    }
  }

  static func sourceName(_ source: CleanupSource) -> String {
    switch source {
    case .smartClean: return String(localized: "Умная очистка")
    case .files: return String(localized: "Большие и старые")
    case .duplicates: return String(localized: "Дубликаты")
    case .apps: return String(localized: "Приложения")
    case .trash: return String(localized: "Корзина")
    case .explorer: return String(localized: "Карта диска")
    }
  }
}

extension CleanupSource {
  var symbol: String {
    switch self {
    case .smartClean: return "sparkles"
    case .files: return "doc"
    case .duplicates: return "square.on.square"
    case .apps: return "square.grid.2x2"
    case .trash: return "trash"
    case .explorer: return "chart.pie"
    }
  }

  /// Icon color and its tile tint, as in the History mock.
  var colors: (icon: Color, tint: Color) {
    switch self {
    case .smartClean, .explorer:
      return (Color(light: 0x0071E3, dark: 0x0A84FF), Color(hex: 0x0071E3, opacity: 0.12))
    case .files:
      return (Color(light: 0x4A48C9, dark: 0x7D7AFF), Color(hex: 0x5E5CE6, opacity: 0.13))
    case .duplicates:
      return (Color(light: 0x16788A, dark: 0x40C8E0), Color(hex: 0x30B0C7, opacity: 0.15))
    case .apps:
      return (Color(light: 0xC25E00, dark: 0xFF9F0A), Color(hex: 0xFF9500, opacity: 0.15))
    case .trash:
      return (Color(light: 0x7A5C36, dark: 0xC8A97E), Color(hex: 0xA2845E, opacity: 0.16))
    }
  }
}
