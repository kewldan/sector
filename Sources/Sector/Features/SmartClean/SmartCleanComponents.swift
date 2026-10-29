import SectorCore
import SwiftUI

// Pieces shared by the three Smart Clean states.

/// A byte count that tweens to new values (and optionally counts up from
/// zero on appear), formatted through `format`.
struct AnimatedBytesText: View {
  var bytes: UInt64
  var font: Font
  var countUp = false
  var duration: Double = 0.55
  var delay: Double = 0
  var format: (String) -> String = { $0 }

  @State private var shown: Double

  init(
    bytes: UInt64, font: Font, countUp: Bool = false, duration: Double = 0.55,
    delay: Double = 0, format: @escaping (String) -> String = { $0 }
  ) {
    self.bytes = bytes
    self.font = font
    self.countUp = countUp
    self.duration = duration
    self.delay = delay
    self.format = format
    _shown = State(initialValue: countUp && !Motion.reduced ? 0 : Double(bytes))
  }

  var body: some View {
    Color.clear.frame(width: 0, height: 0)
      .modifier(BytesTween(value: shown, font: font, format: format))
      .onAppear {
        guard countUp, !Motion.reduced else { return }
        withAnimation(.timingCurve(0.25, 1, 0.5, 1, duration: duration).delay(delay)) {
          shown = Double(bytes)
        }
      }
      .onChange(of: bytes) { _, new in
        withAnimation(Motion.resolve(.timingCurve(0.33, 1, 0.68, 1, duration: duration))) {
          shown = Double(new)
        }
      }
  }
}

private struct BytesTween: ViewModifier, Animatable {
  var value: Double
  var font: Font
  var format: (String) -> String

  nonisolated var animatableData: Double {
    get { value }
    set { value = newValue }
  }

  func body(content: Content) -> some View {
    Text(format(ByteFormat.string(UInt64(max(0, value)))))
      .font(font)
      .monospacedDigit()
      .lineLimit(1)
      .fixedSize()
  }
}

extension View {
  /// Pops the view in with a bouncy scale, like the mock's `chipIn`.
  func popIn(delay: Double, from scale: CGFloat = 0.9, offset: CGFloat = 10) -> some View {
    modifier(PopInModifier(delay: delay, scale: scale, offset: offset))
  }
}

private struct PopInModifier: ViewModifier {
  var delay: Double
  var scale: CGFloat
  var offset: CGFloat
  @State private var visible = false

  func body(content: Content) -> some View {
    content
      .opacity(visible ? 1 : 0)
      .scaleEffect(visible || Motion.reduced ? 1 : scale)
      .offset(y: visible || Motion.reduced ? 0 : offset)
      .onAppear {
        withAnimation(Motion.resolve(Motion.bouncy).delay(Motion.reduced ? 0 : delay)) {
          visible = true
        }
      }
  }
}

/// Horizontal capacity bar that grows in from one edge on appear.
struct GrowingBar<Fill: ShapeStyle>: View {
  var fraction: Double
  var fill: Fill
  var height: CGFloat = 8
  var alignment: Alignment = .leading
  var delay: Double = 0
  var animation: Animation = Motion.smooth

  @State private var grown = false

  var body: some View {
    GeometryReader { geo in
      Capsule()
        .fill(fill)
        .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
        .scaleEffect(x: grown ? 1 : 0.001, anchor: alignment == .leading ? .leading : .trailing)
        .frame(maxWidth: .infinity, alignment: alignment)
    }
    .frame(height: height)
    .background(Color.sectorTrack, in: .capsule)
    .clipShape(.capsule)
    .animation(Motion.resolve(Motion.quick), value: fraction)
    .onAppear {
      withAnimation(Motion.resolve(animation).delay(Motion.reduced ? 0 : delay)) { grown = true }
    }
  }
}

/// Light band sweeping across a button, as on the mock's primary action.
struct SelectionShimmer: ViewModifier {
  var active: Bool

  func body(content: Content) -> some View {
    if active && !Motion.reduced {
      content.overlay {
        GeometryReader { geo in
          let width = geo.size.width
          LinearGradient(
            colors: [.white.opacity(0), .white.opacity(0.45), .white.opacity(0)],
            startPoint: .leading, endPoint: .trailing
          )
          .frame(width: 40)
          .rotationEffect(.degrees(20))
          .keyframeAnimator(initialValue: -0.4, repeating: true) { band, x in
            band.offset(x: x * width)
          } keyframes: { _ in
            LinearKeyframe(-0.4, duration: 1.2)
            CubicKeyframe(1.3, duration: 1.76)
            LinearKeyframe(1.3, duration: 1.44)
          }
        }
        .clipShape(.capsule)
        .allowsHitTesting(false)
      }
    } else {
      content
    }
  }
}

/// Piecewise keyframe interpolation for the particle animations ported
/// from the mocks' CSS: each segment eased by `curve`.
struct Keyframes {
  /// (time 0…1, value)
  var stops: [(Double, Double)]
  var curve: UnitCurve

  func value(at t: Double) -> Double {
    guard let first = stops.first, let last = stops.last else { return 0 }
    if t <= first.0 { return first.1 }
    if t >= last.0 { return last.1 }
    for (a, b) in zip(stops, stops.dropFirst()) where t <= b.0 {
      let local = (t - a.0) / max(0.0001, b.0 - a.0)
      return a.1 + (b.1 - a.1) * curve.value(at: local)
    }
    return last.1
  }
}

extension CleanupCategory.Kind {
  /// Tint from the mock.
  var color: Color {
    switch self {
    case .xcode: Color(hex: 0x5E5CE6)
    case .nodeModules: Color(light: 0x248A3D, dark: 0x30D158)
    case .docker: Color(light: 0x0071E3, dark: 0x0A84FF)
    case .simulators: Color(light: 0x6E6E73, dark: 0x98989D)
    case .appCaches: Color(light: 0x16788A, dark: 0x40C8E0)
    case .trash: Color(light: 0x7A5C36, dark: 0xC4A27A)
    case .logs: Color(light: 0xB25000, dark: 0xFF9F0A)
    case .downloads: Color(light: 0x1E7FA0, dark: 0x64D2FF)
    }
  }

  /// Noun forms for "ещё N …" under a long item list.
  var itemNoun: (String, String, String) {
    switch self {
    case .nodeModules: ("проект", "проекта", "проектов")
    case .appCaches: ("приложение", "приложения", "приложений")
    case .simulators: ("устройство", "устройства", "устройств")
    case .docker: ("образ", "образа", "образов")
    default: ("объект", "объекта", "объектов")
    }
  }
}

/// Gradient of rings and arcs (teal → blue → indigo).
extension LinearGradient {
  static func sectorClean(_ start: UnitPoint = .leading, _ end: UnitPoint = .trailing)
    -> LinearGradient
  {
    LinearGradient(
      stops: [
        .init(color: Color(hex: 0x30B0C7), location: 0),
        .init(color: Color(hex: 0x0071E3), location: 0.55),
        .init(color: Color(hex: 0x5E5CE6), location: 1),
      ], startPoint: start, endPoint: end)
  }
}
