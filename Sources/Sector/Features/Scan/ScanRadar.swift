import SectorCore
import SwiftUI

// The 380 pt disc of the scan screen (design/mockups/Scan.dc.html): a
// rotating radar sweep while scanning, progress in the inner ring, and the
// real category sunburst once the scan finishes.

/// Ring geometry in the 380 pt frame.
enum ScanRadarMetrics {
  static let size: CGFloat = 380
  static let innerRing: ClosedRange<CGFloat> = 78...128
  static let outerRing: ClosedRange<CGFloat> = 132...170
  static let center: CGFloat = 150
}

/// Two-level sunburst: categories in the inner ring, the largest folders of
/// each category (with the remainder) in the outer ring.
struct ScanSunburst: Sendable, Equatable {
  struct Arc: Sendable, Equatable, Identifiable {
    var id: Int
    /// Fractions of the full circle, clockwise from 12 o'clock.
    var start: Double
    var end: Double
    var hex: UInt32
    var outer: Bool
    var opacity: Double
    /// Position in the reveal order.
    var order: Int
  }

  var arcs: [Arc]
  var version: Int

  /// Walks the tree once (off the main actor): every node whose category
  /// differs from its parent's starts a "category entry" (a project, an
  /// app container, ~/Library…); the three largest entries of each category
  /// split its span in the outer ring.
  static func compute(tree: FileTree, breakdown: CategoryBreakdown, version: Int) -> ScanSunburst {
    let cases = DiskCategory.allCases
    let ordered = breakdown.ordered
    let total = Double(ordered.reduce(UInt64(0)) { $0 &+ $1.size })
    guard total > 0 else { return ScanSunburst(arcs: [], version: version) }

    var top = [[UInt64]](repeating: [], count: cases.count)
    let cats = breakdown.nodeCategories
    let count = min(tree.count, cats.count)
    if count > 1 {
      for i in 1..<count {
        let id = NodeID(i)
        guard let parent = tree.parent(id), cats[i] != cats[Int(parent)], !tree.isRemoved(id)
        else { continue }
        let raw = Int(cats[i])
        guard raw < top.count else { continue }
        let size = tree.size(id)
        if top[raw].count < 3 {
          top[raw].append(size)
          top[raw].sort(by: >)
        } else if size > top[raw][2] {
          top[raw][2] = size
          top[raw].sort(by: >)
        }
      }
    }

    var arcs: [Arc] = []
    var angle = 0.0
    var outerOrder = 0
    for (index, entry) in ordered.enumerated() {
      let span = Double(entry.size) / total
      guard span > 0.001 else {
        angle += span
        continue
      }
      let hex = entry.category.hex
      arcs.append(
        Arc(
          id: arcs.count, start: angle, end: angle + span, hex: hex, outer: false, opacity: 1,
          order: index))

      let raw = cases.firstIndex(of: entry.category) ?? 0
      let entries = top[raw]
      let denominator = Double(max(entries.reduce(0, &+), entry.size))
      var parts = entries.map { Double($0) / denominator }.filter { $0 * span > 0.004 }
      let rest = 1 - parts.reduce(0, +)
      if rest > 0.02 || parts.isEmpty { parts.append(max(rest, 0)) }
      let scale = 1 / max(parts.reduce(0, +), 0.0001)
      var b = angle
      for (j, part) in parts.enumerated() {
        let s = span * part * scale
        arcs.append(
          Arc(
            id: arcs.count, start: b, end: b + s, hex: hex, outer: true,
            opacity: j % 2 == 0 ? 1 : 0.7, order: outerOrder))
        b += s
        outerOrder += 1
      }
      angle += span
    }
    return ScanSunburst(arcs: arcs, version: version)
  }
}

/// The whole disc. Inputs are plain values so SwiftUI skips the heavy
/// children when only the counter changes.
struct ScanRadar: View {
  /// Determinate progress, or nil for an indeterminate scan.
  var fraction: Double?
  var isRunning: Bool
  var isFinished: Bool
  var sunburst: ScanSunburst?
  var bytes: UInt64
  var caption: String
  var captionColor: Color

  var body: some View {
    let m = ScanRadarMetrics.self
    ZStack {
      ScanSweep(isRunning: isRunning)
        .opacity(isRunning ? 1 : 0)

      // Tracks.
      Circle()
        .strokeBorder(Color.primary.opacity(0.045), lineWidth: 50)
        .frame(width: m.innerRing.upperBound * 2, height: m.innerRing.upperBound * 2)
      Circle()
        .strokeBorder(Color.primary.opacity(0.035), lineWidth: 38)
        .frame(width: m.outerRing.upperBound * 2, height: m.outerRing.upperBound * 2)

      if let fraction, !isFinished {
        ScanProgressArc(fraction: fraction)
          .transition(.opacity)
      }

      if isFinished, let sunburst {
        ScanSunburstView(sunburst: sunburst)
          .id(sunburst.version)
          .transition(.opacity)
      }

      ScanCenterDisc(bytes: bytes, caption: caption, captionColor: captionColor)
    }
    .frame(width: m.size, height: m.size)
  }
}

/// Inner-ring progress while scanning (determinate scans only).
private struct ScanProgressArc: View {
  var fraction: Double

  var body: some View {
    let m = ScanRadarMetrics.self
    ScanArcShape(
      start: 0, end: max(0.002, min(1, fraction)), inner: m.innerRing.lowerBound,
      outer: m.innerRing.upperBound
    )
    .fill(
      AngularGradient(
        colors: [Color(hex: 0x0071E3), Color(hex: 0x5E5CE6), Color(hex: 0x0071E3)],
        center: .center, startAngle: .degrees(-90), endAngle: .degrees(270))
    )
    .opacity(0.85)
    .animation(.linear(duration: 0.2), value: fraction)
    .frame(width: ScanRadarMetrics.size, height: ScanRadarMetrics.size)
    .accessibilityHidden(true)
  }
}

/// Rotating conic sweep and an expanding pulse ring, 2.2 s per turn.
private struct ScanSweep: View {
  var isRunning: Bool
  @State private var start = Date()

  var body: some View {
    let reduced = Motion.reduced
    TimelineView(.animation(minimumInterval: nil, paused: !isRunning || reduced)) { context in
      let t = context.date.timeIntervalSince(start)
      let p = t.truncatingRemainder(dividingBy: 2.2) / 2.2
      let eased = 1 - pow(1 - p, 3)
      ZStack {
        Circle()
          .fill(
            AngularGradient(
              stops: [
                .init(color: Color(hex: 0x0071E3, opacity: 0), location: 0),
                .init(color: Color(hex: 0x0071E3, opacity: 0), location: 290 / 360),
                .init(color: Color(hex: 0x0071E3, opacity: 0.22), location: 358 / 360),
                .init(color: Color(hex: 0x0071E3, opacity: 0.5), location: 1),
              ], center: .center, startAngle: .degrees(-90), endAngle: .degrees(270))
          )
          .rotationEffect(.degrees(reduced ? 0 : p * 360))
        if !reduced {
          Circle()
            .strokeBorder(Color(hex: 0x0071E3, opacity: 0.25), lineWidth: 1.5)
            .scaleEffect(0.95 + 0.3 * eased)
            .opacity(0.6 * (1 - eased))
        }
      }
    }
    .frame(width: ScanRadarMetrics.size, height: ScanRadarMetrics.size)
    .accessibilityHidden(true)
  }
}

/// Category segments that pop in one after another.
private struct ScanSunburstView: View {
  var sunburst: ScanSunburst
  @State private var shown = false
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let m = ScanRadarMetrics.self
    let separator = scheme == .dark ? Color(hex: 0x1F2026) : Color.white.opacity(0.95)
    ZStack {
      ForEach(sunburst.arcs) { arc in
        let shape = ScanArcShape(
          start: arc.start, end: arc.end,
          inner: arc.outer ? m.outerRing.lowerBound : m.innerRing.lowerBound,
          outer: arc.outer ? m.outerRing.upperBound : m.innerRing.upperBound)
        let base = Color(hex: arc.hex)
        let delay =
          arc.outer ? 0.35 + Double(min(arc.order, 24)) * 0.025 : Motion.stagger(arc.order)
        shape
          .fill(arc.outer ? base.mix(with: .white, by: 0.4) : base)
          .overlay(shape.stroke(separator, style: StrokeStyle(lineWidth: 2, lineJoin: .round)))
          .opacity(shown ? arc.opacity : 0)
          .scaleEffect(shown || Motion.reduced ? 1 : 0.84)
          .rotationEffect(.degrees(shown || Motion.reduced ? 0 : -16))
          .animation(
            Motion.resolve(.spring(duration: 0.9, bounce: 0.3)).delay(Motion.reduced ? 0 : delay),
            value: shown)
      }
    }
    .frame(width: m.size, height: m.size)
    .onAppear { shown = true }
    .accessibilityHidden(true)
  }
}

/// The glassy center with the scanned-bytes counter.
private struct ScanCenterDisc: View {
  var bytes: UInt64
  var caption: String
  var captionColor: Color
  @State private var breathe = false

  var body: some View {
    let parts = ByteFormat.parts(bytes)
    VStack(spacing: 0) {
      Text(parts.number)
        .font(.system(size: 30, weight: .bold))
        .tracking(-0.6)
        .monospacedDigit()
        .contentTransition(.numericText(value: Double(bytes)))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      Text("\(parts.unit) найдено")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      Text(caption)
        .font(.system(size: 11, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(captionColor)
        .contentTransition(.numericText())
        .padding(.top, 4)
    }
    .padding(.horizontal, 14)
    .frame(width: ScanRadarMetrics.center, height: ScanRadarMetrics.center)
    .background(.regularMaterial, in: .circle)
    .background(Color.sectorCard, in: .circle)
    .overlay(Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    .shadow(color: Color(hex: 0x141E46).opacity(0.12), radius: 15, y: 10)
    .scaleEffect(breathe ? 1.035 : 1)
    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: breathe)
    .onAppear {
      if !Motion.reduced { breathe = true }
    }
    .accessibilityElement(children: .combine)
  }
}

/// Ring segment between two radii (points, in the 380 pt frame) and two
/// fractions of the circle measured clockwise from 12 o'clock.
struct ScanArcShape: Shape {
  var start: Double
  var end: Double
  var inner: CGFloat
  var outer: CGFloat

  var animatableData: AnimatablePair<Double, Double> {
    get { AnimatablePair(start, end) }
    set {
      start = newValue.first
      end = newValue.second
    }
  }

  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width, rect.height) / ScanRadarMetrics.size
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let a0 = Angle.degrees(-90 + start * 360)
    let a1 = Angle.degrees(-90 + min(end, start + 0.99999) * 360)
    var path = Path()
    path.addArc(
      center: center, radius: outer * scale, startAngle: a0, endAngle: a1, clockwise: false)
    path.addArc(
      center: center, radius: inner * scale, startAngle: a1, endAngle: a0, clockwise: true)
    path.closeSubpath()
    return path
  }
}
