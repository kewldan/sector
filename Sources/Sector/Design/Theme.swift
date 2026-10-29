import AppKit
import SectorCore
import SwiftUI

// Design tokens from the "Дизайн-система · macOS 27" board
// (design/mockups/DesignSystem.dc.html).

extension Color {
  init(hex: UInt32, opacity: Double = 1) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255, opacity: opacity)
  }

  /// A color that switches between light and dark appearances.
  init(light: UInt32, dark: UInt32) {
    self.init(
      nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let hex = isDark ? dark : light
        return NSColor(
          srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
          blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
      })
  }

  /// Actions and selection · 4.7:1 on white.
  static let sectorAccent = Color(light: 0x0071E3, dark: 0x0A84FF)
  static let sectorAccentPressed = Color(light: 0x0058B0, dark: 0x409CFF)
  /// Done, safe.
  static let sectorSuccess = Color(light: 0x248A3D, dark: 0x30D158)
  /// Only for irreversible actions.
  static let sectorDanger = Color(light: 0xE5243B, dark: 0xFF453A)
  /// "Проверьте" badges and warnings.
  static let sectorWarning = Color(light: 0xC2410C, dark: 0xFF9F0A)
  static let sectorWarningFill = Color(hex: 0xFF9500)

  /// Card fill on the window background.
  static let sectorCard = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 1, alpha: 0.72)
    })
  /// Hairline around cards and rows.
  static let sectorHairline = Color.primary.opacity(0.08)
  /// Filled track of rings, bars and controls.
  static let sectorTrack = Color.primary.opacity(0.07)
}

extension DiskCategory {
  var color: Color { Color(hex: hex) }
}

/// Corner radii and spacing (scale step 4).
enum Metrics {
  static let windowRadius: CGFloat = 26
  static let cardRadius: CGFloat = 22
  static let sidebarRadius: CGFloat = 18
  static let rowRadius: CGFloat = 14
  static let iconRadius: CGFloat = 10
  static let pagePadding: CGFloat = 28
  static let cardPadding: CGFloat = 20
  static let gap: CGFloat = 16
}

/// Motion tokens. Every animation explains cause and effect; with "Reduce
/// Motion" or the in-app toggle off they collapse to quick fades.
enum Motion {
  /// cubic-bezier(.32,.72,0,1), 600–900 ms: windows, panels, cards, segments.
  static let smooth = Animation.spring(duration: 0.7, bounce: 0)
  /// cubic-bezier(.34,1.56,.64,1), 400–650 ms: toggles, badges, popovers, checks.
  static let bouncy = Animation.spring(duration: 0.5, bounce: 0.32)
  /// cubic-bezier(.2,.8,.2,1), 150–250 ms: hover, press, color.
  static let quick = Animation.spring(duration: 0.2, bounce: 0)
  /// Counters: ease-out cubic, 1.5 s.
  static let counter = Animation.timingCurve(0.33, 1, 0.68, 1, duration: 1.5)

  @MainActor static var reduced: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      || !(UserDefaults.standard.object(forKey: "animationsEnabled") as? Bool ?? true)
  }

  /// `animation`, or a short fade when motion is reduced.
  @MainActor static func resolve(_ animation: Animation) -> Animation {
    reduced ? .easeOut(duration: 0.15) : animation
  }

  /// Staggered delay for list items appearing one after another.
  static func stagger(_ index: Int, step: Double = 0.06, base: Double = 0) -> Double {
    base + Double(min(index, 12)) * step
  }
}

/// Typography from the design system.
extension Font {
  /// Big numbers · 64/800.
  static let sectorHero = Font.system(size: 56, weight: .heavy).monospacedDigit()
  /// Screen title · 30/700.
  static let sectorLargeTitle = Font.system(size: 30, weight: .bold)
  /// Section · 20/700.
  static let sectorSection = Font.system(size: 20, weight: .bold)
  /// Toolbar · 15/700.
  static let sectorToolbar = Font.system(size: 15, weight: .bold)
  /// Body · 13/400.
  static let sectorBody = Font.system(size: 13)
  /// Caption · 11/600, used uppercased for section labels.
  static let sectorCaption = Font.system(size: 11, weight: .semibold)
  /// Paths · mono 12.
  static let sectorPath = Font.system(size: 12, design: .monospaced)
}
