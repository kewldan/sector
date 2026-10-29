// Renders the app icon from the welcome-screen mock into an .iconset and
// converts it to Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024

func draw(in ctx: CGContext) {
  // macOS icon grid: 824 pt body centered on a 1024 canvas.
  let body = CGRect(x: 100, y: 100, width: 824, height: 824)
  let radius: CGFloat = 185
  let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
  let space = CGColorSpace(name: CGColorSpace.sRGB)!
  func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
  }

  // Drop shadow.
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x0A2A6E, 0.35))
  ctx.addPath(shape)
  ctx.setFillColor(color(0x0A84FF))
  ctx.fillPath()
  ctx.restoreGState()

  // Body gradient, top-left to bottom-right.
  ctx.saveGState()
  ctx.addPath(shape)
  ctx.clip()
  let gradient = CGGradient(
    colorsSpace: space, colors: [color(0x5AC8FA), color(0x0A84FF), color(0x5E5CE6)] as CFArray,
    locations: [0, 0.5, 1])!
  ctx.drawLinearGradient(
    gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY),
    options: [])
  // Top gloss.
  let gloss = CGGradient(
    colorsSpace: space, colors: [color(0xFFFFFF, 0.55), color(0xFFFFFF, 0)] as CFArray,
    locations: [0, 1])!
  ctx.drawLinearGradient(
    gloss, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.maxY - body.height * 0.45),
    options: [])
  ctx.restoreGState()

  // Hairline rim.
  ctx.addPath(
    CGPath(
      roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: radius - 3, cornerHeight: radius - 3,
      transform: nil))
  ctx.setStrokeColor(color(0xFFFFFF, 0.5))
  ctx.setLineWidth(6)
  ctx.strokePath()

  // Ring: faint track, then the used-space arc from 12 o'clock clockwise.
  let center = CGPoint(x: body.midX, y: body.midY)
  let ringRadius = body.width * 34 / 120
  let lineWidth = body.width * 12 / 120
  ctx.setLineCap(.round)
  ctx.setLineWidth(lineWidth)
  ctx.addArc(center: center, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
  ctx.setStrokeColor(color(0xFFFFFF, 0.28))
  ctx.strokePath()

  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x1B2A8A, 0.35))
  let start = CGFloat.pi / 2
  ctx.addArc(
    center: center, radius: ringRadius, startAngle: start, endAngle: start - .pi * 2 * 0.62,
    clockwise: true)
  ctx.setStrokeColor(color(0xFFFFFF))
  ctx.strokePath()
  ctx.restoreGState()

  ctx.addEllipse(
    in: CGRect(
      x: center.x - body.width * 15 / 120, y: center.y - body.width * 15 / 120,
      width: body.width * 30 / 120, height: body.width * 30 / 120))
  ctx.setFillColor(color(0xFFFFFF, 0.94))
  ctx.fillPath()
}

func png(size: Int) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
  ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
  draw(in: ctx)
  return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
  .deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
  try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
  try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(size: 1024).write(to: root.appendingPathComponent("design/AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
  "-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path,
]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Resources/AppIcon.icns" : "iconutil failed")
