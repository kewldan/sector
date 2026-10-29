import AppKit
import SectorCore
import SwiftUI

/// Opens and focuses the main window from code without a scene context:
/// notification actions, the menu bar panel, banners.
@MainActor
enum AppWindow {
  /// Captured from a live view's environment (`capturesOpenWindow()`).
  static var openWindow: OpenWindowAction?

  static func showMain() {
    NSApp.activate()
    if let openWindow {
      openWindow(id: "main")
    } else if let window = NSApp.windows.first(where: {
      $0.identifier?.rawValue.hasPrefix("main") == true
    }) {
      window.makeKeyAndOrderFront(nil)
    }
  }
}

extension View {
  /// Remembers the scene's `openWindow` so non-view code can reopen the main
  /// window after the user closed it.
  func capturesOpenWindow() -> some View { modifier(CaptureOpenWindow()) }
}

private struct CaptureOpenWindow: ViewModifier {
  @Environment(\.openWindow) private var openWindow

  func body(content: Content) -> some View {
    content.onAppear { AppWindow.openWindow = openWindow }
  }
}

extension AppModel {
  /// Brings the main window forward on `route`.
  func presentInMainWindow(_ route: Route) {
    AppWindow.showMain()
    showsScan = false
    self.route = route
  }

  /// "Очистить" / "Быстрая очистка": runs Smart Clean on its safe selection,
  /// or scans first when there is nothing to clean from yet.
  func startQuickClean() {
    guard tree != nil else {
      AppWindow.showMain()
      if isScanning { showsScan = true } else { startScan() }
      return
    }
    presentInMainWindow(.smartClean)
    smartClean.startCleaning()
  }

  /// Bytes of `gigabytes` in the units the user picked.
  static func bytes(gigabytes: Int) -> UInt64 {
    UInt64(Double(max(0, gigabytes)) * ByteFormat.base * ByteFormat.base * ByteFormat.base)
  }
}

/// `animation` delayed by `delay`, or a plain short fade when motion is
/// reduced (no stagger).
@MainActor func stagedAnimation(_ animation: Animation, delay: Double) -> Animation {
  Motion.reduced ? Motion.resolve(animation) : animation.delay(delay)
}

/// "2 месяца", "3 недели", "5 дней" — how far away a forecast date is, in
/// the accusative after «через».
enum ForecastText {
  static func duration(days: Int) -> String {
    switch days {
    case ..<14:
      let n = max(1, days)
      return n == 1
        ? String(localized: "forecast.oneDay") : Plural.format(n, "день", "дня", "дней")
    case ..<60:
      let n = Int((Double(days) / 7).rounded())
      return Plural.format(n, "неделю", "недели", "недель")
    case ..<365:
      let n = Int((Double(days) / 30.4).rounded())
      return Plural.format(n, "месяц", "месяца", "месяцев")
    default:
      let n = Int((Double(days) / 365).rounded())
      return n == 1 ? String(localized: "forecast.oneYear") : Plural.format(n, "год", "года", "лет")
    }
  }

  /// Forecasts further than this are noise and stay hidden.
  static let horizonDays = 3 * 365
}
