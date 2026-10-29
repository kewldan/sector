import Foundation
import SectorCore
import SwiftUI

/// One row of "Большие и старые файлы".
struct LargeFile: Identifiable, Hashable, Sendable {
  var id: String { path }
  let path: String
  let name: String
  /// Parent folder with the home folder shown as "~".
  let folder: String
  let size: UInt64
  /// Modification date from the scan; fallback for "Открывался".
  let modified: Date

  var url: URL { URL(fileURLWithPath: path) }
  var pathExtension: String { (name as NSString).pathExtension.lowercased() }

  /// Badge text: "MOV", "PVM", "TGZ".
  var kindLabel: String {
    let lower = name.lowercased()
    if lower.hasSuffix(".tar.gz") { return "TGZ" }
    let ext = pathExtension.uppercased()
    return ext.isEmpty ? "FILE" : String(ext.prefix(4))
  }

  var kindColor: Color { FileKindStyle.color(forExtension: pathExtension) }
}

enum LargeFilesFilter: CaseIterable, Hashable {
  case all, old, big

  var title: LocalizedStringKey {
    switch self {
    case .all: return "Все"
    case .old: return "Старше полугода"
    case .big: return "Больше 20 ГБ"
    }
  }
}

enum LargeFilesSort: Hashable {
  case name, opened, size

  /// Direction a column starts with when first picked.
  var defaultAscending: Bool {
    switch self {
    case .name: return true
    case .opened: return true  // oldest first
    case .size: return false  // largest first
    }
  }
}

/// Off-main lookups for the large files list.
enum LargeFilesScan {
  /// Live files of at least `minSize`, skipping the Trash.
  static func collect(_ tree: FileTree, minSize: UInt64, home: String) -> [LargeFile] {
    let trash = home + "/.Trash/"
    return tree.files(atLeast: minSize).compactMap { id -> LargeFile? in
      let path = tree.path(id)
      guard !path.hasPrefix(trash) else { return nil }
      let parent = (path as NSString).deletingLastPathComponent
      let folder: String
      if parent == home {
        folder = "~"
      } else if parent.hasPrefix(home + "/") {
        folder = "~" + parent.dropFirst(home.count)
      } else {
        folder = parent
      }
      return LargeFile(
        path: path, name: tree.name(id), folder: folder, size: tree.size(id),
        modified: tree.modificationDate(id))
    }
  }

  /// "Last opened" per path from Spotlight, falling back to the
  /// modification date.
  static func openedDates(_ files: [LargeFile]) -> [String: Date] {
    var result: [String: Date] = [:]
    result.reserveCapacity(files.count)
    for file in files {
      result[file.path] = FileMetadata.lastUsedDate(file.url) ?? file.modified
    }
    return result
  }
}

/// "Сегодня", "7 мес. назад", "1 год назад".
@MainActor
enum OpenedFormat {
  private static let short: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    f.dateTimeStyle = .numeric
    return f
  }()

  private static let full: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    f.dateTimeStyle = .numeric
    return f
  }()

  static func string(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    if date >= now || calendar.isDateInToday(date) { return String(localized: "Сегодня") }
    if calendar.isDateInYesterday(date) { return String(localized: "Вчера") }
    let years = calendar.dateComponents([.year], from: date, to: now).year ?? 0
    let text = (years >= 1 ? full : short).localizedString(for: date, relativeTo: now)
    return text.prefix(1).uppercased() + text.dropFirst()
  }

  /// Whole months between `date` and now.
  static func months(since date: Date, now: Date = Date()) -> Int {
    Calendar.current.dateComponents([.month], from: date, to: now).month ?? 0
  }
}
