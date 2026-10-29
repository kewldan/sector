import SwiftUI

/// Sidebar destinations of the main window.
enum Route: String, Hashable, CaseIterable, Identifiable {
  case overview, explorer, smartClean, largeFiles, duplicates, apps, history

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .overview: return "Обзор"
    case .explorer: return "Карта диска"
    case .smartClean: return "Умная очистка"
    case .largeFiles: return "Большие и старые"
    case .duplicates: return "Дубликаты"
    case .apps: return "Приложения"
    case .history: return "История"
    }
  }

  var symbol: String {
    switch self {
    case .overview: return "gauge.with.dots.needle.33percent"
    case .explorer: return "chart.pie"
    case .smartClean: return "sparkles"
    case .largeFiles: return "doc"
    case .duplicates: return "square.on.square"
    case .apps: return "square.grid.2x2"
    case .history: return "clock.arrow.circlepath"
    }
  }

  /// Sidebar sections: "Диск" and "Инструменты".
  static let disk: [Route] = [.overview, .explorer, .smartClean]
  static let tools: [Route] = [.largeFiles, .duplicates, .apps, .history]
}
