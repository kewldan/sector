import AppKit
import SectorCore
import SwiftUI

/// Menu bar icon: ring of used space and/or free space, per
/// `settings.menuBarStyle`. The ring is a template image, so the menu bar
/// tints it for light, dark and selected states.
struct MenuBarLabel: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let volume = model.volume
    let percent = Int(((volume?.usedFraction ?? 0) * 100).rounded())
    let free = volume.map { ByteFormat.string($0.available) } ?? "—"
    Group {
      switch model.settings.menuBarStyle {
      case .ring:
        Image(nsImage: MenuBarRing.image(percent: percent))
      case .ringAndSize:
        HStack(spacing: 4) {
          Image(nsImage: MenuBarRing.image(percent: percent))
          Text(free).monospacedDigit()
        }
      case .sizeOnly:
        Text(free).monospacedDigit()
      }
    }
    .accessibilityLabel(Text("Sector: \(free) свободно"))
    .capturesOpenWindow()
  }
}

/// Template ring images for the menu bar, cached per whole percent.
@MainActor
enum MenuBarRing {
  private static var cache: [Int: NSImage] = [:]

  static func image(percent: Int, size: CGFloat = 16) -> NSImage {
    let percent = max(0, min(100, percent))
    let key = percent * 1000 + Int(size)
    if let cached = cache[key] { return cached }
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      let line = size * 0.14
      let radius = size * 0.34
      let center = NSPoint(x: rect.midX, y: rect.midY)
      let track = NSBezierPath()
      track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
      track.lineWidth = line
      NSColor.black.withAlphaComponent(0.3).setStroke()
      track.stroke()
      if percent > 0 {
        let arc = NSBezierPath()
        arc.appendArc(
          withCenter: center, radius: radius, startAngle: 90,
          endAngle: 90 - 360 * CGFloat(percent) / 100, clockwise: true)
        arc.lineWidth = line
        arc.lineCapStyle = .round
        NSColor.black.setStroke()
        arc.stroke()
      }
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = String(localized: "Занято \(percent)%")
    cache[key] = image
    return image
  }
}
