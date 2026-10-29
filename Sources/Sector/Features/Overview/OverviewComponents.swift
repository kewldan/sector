import SectorCore
import SwiftUI

/// Big-number byte formatting: one decimal at every unit ("994,7 ГБ"),
/// with the unit fixed by the target so counters never flip units midway.
enum HeroBytes {
  static func unitIndex(_ bytes: UInt64) -> Int {
    var value = Double(bytes)
    var index = 0
    while value >= ByteFormat.base * 0.9995 && index < 5 {
      value /= ByteFormat.base
      index += 1
    }
    return index
  }

  static func number(_ bytes: Double, unit: Int) -> String {
    let value = max(0, bytes) / pow(ByteFormat.base, Double(unit))
    return value.formatted(.number.precision(.fractionLength(unit == 0 ? 0 : 1)))
  }

  static func string(_ bytes: UInt64) -> String {
    let unit = unitIndex(bytes)
    return "\(number(Double(bytes), unit: unit)) \(ByteFormat.localizedUnit(unit))"
  }
}

/// A byte count that counts up from zero on appearance with the design's
/// counter curve, then follows changes.
struct CountingByteText: View {
  var bytes: UInt64
  var showsUnit = true
  /// Animates later changes; nil switches instantly.
  var changeAnimation: Animation? = Motion.smooth
  var delay: Double = 0.25

  @State private var shown: Double?

  var body: some View {
    ByteNumberText(value: shown ?? 0, unit: HeroBytes.unitIndex(bytes), showsUnit: showsUnit)
      .onAppear {
        guard shown == nil else { return }
        if Motion.reduced {
          shown = Double(bytes)
        } else {
          shown = 0
          withAnimation(Motion.counter.delay(delay)) { shown = Double(bytes) }
        }
      }
      .onChange(of: bytes) { _, new in
        if let changeAnimation {
          withAnimation(Motion.resolve(changeAnimation)) { shown = Double(new) }
        } else {
          shown = Double(new)
        }
      }
  }
}

private struct ByteNumberText: View, Animatable {
  var value: Double
  var unit: Int
  var showsUnit: Bool

  nonisolated var animatableData: Double {
    get { value }
    set { value = newValue }
  }

  var body: some View {
    let number = HeroBytes.number(value, unit: unit)
    Text(showsUnit ? "\(number) \(ByteFormat.localizedUnit(unit))" : number)
      .monospacedDigit()
  }
}

/// Card surface of the overview (the mock's white .72 panel).
struct OverviewCardBackground: ViewModifier {
  var radius: CGFloat = Metrics.cardRadius

  func body(content: Content) -> some View {
    content
      .background(Color.sectorCard, in: .rect(cornerRadius: radius))
      .overlay(
        RoundedRectangle(cornerRadius: radius).strokeBorder(Color.sectorHairline, lineWidth: 0.5)
      )
      .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
  }
}

extension View {
  func overviewCard(radius: CGFloat = Metrics.cardRadius) -> some View {
    modifier(OverviewCardBackground(radius: radius))
  }

  /// Hover lift of the mock's `.lift` cards.
  func hoverLift() -> some View { modifier(HoverLift()) }
}

private struct HoverLift: ViewModifier {
  @State private var hovered = false

  func body(content: Content) -> some View {
    content
      .offset(y: hovered ? -2 : 0)
      .shadow(color: Color(hex: 0x141E46).opacity(hovered ? 0.13 : 0), radius: 17, y: 14)
      .onHover { hovered = $0 }
      .animation(Motion.resolve(Motion.smooth), value: hovered)
  }
}

/// Two columns whose widths keep `ratio` (first : second) and whose heights
/// match the taller one.
struct RatioRow: Layout {
  var ratio: CGFloat
  var spacing: CGFloat = Metrics.gap

  private func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
    let available = max(0, total - spacing)
    let first = available * ratio / (ratio + 1)
    return (first, available - first)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width: CGFloat = proposal.width ?? 800
    let (w0, w1) = widths(width)
    var height: CGFloat = 0
    for (view, w) in zip(subviews, [w0, w1]) {
      height = max(height, view.sizeThatFits(ProposedViewSize(width: w, height: nil)).height)
    }
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let (w0, w1) = widths(bounds.width)
    var x = bounds.minX
    for (view, w) in zip(subviews, [w0, w1]) {
      view.place(
        at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
        proposal: ProposedViewSize(width: w, height: bounds.height))
      x += w + spacing
    }
  }
}
