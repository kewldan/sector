import AppKit
import Foundation
import SectorCore
import UniformTypeIdentifiers

/// "Экспорт отчёта": History records as CSV or Markdown.
@MainActor
enum HistoryReport {
  enum Format {
    case csv, markdown

    var fileExtension: String { self == .csv ? "csv" : "md" }

    var contentType: UTType {
      switch self {
      case .csv: return .commaSeparatedText
      case .markdown: return UTType(filenameExtension: "md") ?? .plainText
      }
    }
  }

  /// Asks where to save and writes the report off-main. Returns the saved
  /// file, or nil when cancelled or the write failed.
  static func export(_ records: [CleanupRecord], format: Format) async -> URL? {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [format.contentType]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    let day = Date().formatted(.iso8601.year().month().day())
    panel.nameFieldStringValue =
      String(localized: "Отчёт Sector \(day)") + "." + format.fileExtension
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    let text = make(records, format: format)
    let written = await Task.detached(priority: .userInitiated) { () -> Bool in
      do {
        try Data(text.utf8).write(to: url, options: .atomic)
        return true
      } catch {
        return false
      }
    }.value
    return written ? url : nil
  }

  static func make(_ records: [CleanupRecord], format: Format, now: Date = Date()) -> String {
    switch format {
    case .csv: return csv(records)
    case .markdown: return markdown(records, now: now)
    }
  }

  private static func modeName(_ record: CleanupRecord) -> String {
    record.mode == .trash ? String(localized: "В Корзину") : String(localized: "Навсегда")
  }

  private static func dateString(_ date: Date) -> String {
    date.formatted(date: .numeric, time: .shortened)
  }

  // MARK: - CSV

  private static func csv(_ records: [CleanupRecord]) -> String {
    let header = [
      String(localized: "Дата"), String(localized: "Источник"), String(localized: "Название"),
      String(localized: "Подробности"), String(localized: "Способ"), String(localized: "Объектов"),
      String(localized: "Восстановлено"), String(localized: "Освобождено"),
      String(localized: "Освобождено, байт"),
    ]
    var lines = [header.map(field).joined(separator: ",")]
    for r in records {
      let row = [
        r.date.formatted(.iso8601), HistoryFormat.sourceName(r.source), r.title, r.detail,
        modeName(r), String(r.items.count), String(r.restoredPaths.count),
        ByteFormat.string(r.netFreedBytes), String(r.netFreedBytes),
      ]
      lines.append(row.map(field).joined(separator: ","))
    }
    // BOM so spreadsheet apps read Cyrillic as UTF-8.
    return "\u{FEFF}" + lines.joined(separator: "\r\n") + "\r\n"
  }

  private static func field(_ value: String) -> String {
    guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
      return value
    }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  // MARK: - Markdown

  private static func markdown(_ records: [CleanupRecord], now: Date) -> String {
    let total = records.reduce(UInt64(0)) { $0 + $1.netFreedBytes }
    let halfYear = Calendar.current.date(byAdding: .month, value: -6, to: now) ?? now
    let recent = records.filter { $0.date >= halfYear }.reduce(UInt64(0)) { $0 + $1.netFreedBytes }
    var out = "# " + String(localized: "Отчёт Sector") + "\n\n"
    out += String(localized: "Создан: \(dateString(now))") + "\n\n"
    out += "- " + String(localized: "Всего освобождено: \(ByteFormat.string(total))") + "\n"
    out += "- " + String(localized: "За полгода: \(ByteFormat.string(recent))") + "\n"
    out += "- " + String(localized: "Записей: \(records.count)") + "\n\n"
    guard !records.isEmpty else { return out }
    let columns = [
      String(localized: "Дата"), String(localized: "Что"), String(localized: "Подробности"),
      String(localized: "Способ"), String(localized: "Освобождено"),
    ]
    out += "| " + columns.joined(separator: " | ") + " |\n"
    out += "|" + String(repeating: " --- |", count: columns.count - 1) + " ---: |\n"
    for r in records {
      var how = modeName(r)
      if !r.restoredPaths.isEmpty {
        how += " · " + String(localized: "восстановлено \(r.restoredPaths.count)")
      }
      let cells = [
        dateString(r.date), HistoryFormat.title(r), HistoryFormat.detail(r), how,
        ByteFormat.string(r.netFreedBytes),
      ]
      out += "| " + cells.map(cell).joined(separator: " | ") + " |\n"
    }
    return out
  }

  private static func cell(_ value: String) -> String {
    value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
  }
}
