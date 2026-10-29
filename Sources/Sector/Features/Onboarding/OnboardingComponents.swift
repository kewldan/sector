import SectorCore
import SwiftUI

// Pieces shared by the welcome and permission screens
// (design/mockups/Main.dc.html, Permission.dc.html).

/// The Sector app icon drawn in SwiftUI: a blue-to-indigo rounded square
/// with a white ring arc. `arc` animates (the welcome screen draws it in).
struct OnboardingAppIcon: View {
  var size: CGFloat = 128
  /// Visible share of the white arc, 0...1.
  var arc: Double = 0.62
  /// Highlight, rim and center dot; off for the small list-row icon.
  var detailed = true

  var body: some View {
    let k = size / 128
    let shape = RoundedRectangle(cornerRadius: 28 * k, style: .continuous)
    let ringWidth = (detailed ? 12 : 14) * k
    ZStack {
      shape.fill(
        LinearGradient(
          stops: [
            .init(color: Color(hex: 0x5AC8FA), location: 0),
            .init(color: Color(hex: 0x0A84FF), location: 0.5),
            .init(color: Color(hex: 0x5E5CE6), location: 1),
          ], startPoint: .topLeading, endPoint: .bottomTrailing))
      if detailed {
        shape.fill(
          LinearGradient(
            stops: [
              .init(color: .white.opacity(0.6), location: 0),
              .init(color: .white.opacity(0), location: 0.45),
            ], startPoint: .top, endPoint: .bottom))
        shape.strokeBorder(.white.opacity(0.55), lineWidth: max(0.5, k))
      }
      Circle()
        .stroke(.white.opacity(detailed ? 0.28 : 0.3), lineWidth: ringWidth)
        .frame(width: 68 * k, height: 68 * k)
      Circle()
        .trim(from: 0, to: max(0.0001, arc))
        .stroke(.white, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .frame(width: 68 * k, height: 68 * k)
        .opacity(arc > 0.001 ? 1 : 0)
      if detailed {
        Circle().fill(.white.opacity(0.92)).frame(width: 30 * k, height: 30 * k)
      }
    }
    .frame(width: 120 * k, height: 120 * k)
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// "Шаг N из 3": the current dot grows into a pill after `delay`.
struct OnboardingStepDots: View {
  /// Zero-based current step.
  var current: Int
  var total = 3
  var delay: Double = 1.1
  @State private var grown = false

  var body: some View {
    HStack(spacing: 6) {
      ForEach(0..<total, id: \.self) { i in
        Capsule()
          .fill(i == current ? Color.sectorAccent : Color.primary.opacity(0.18))
          .frame(width: i == current && grown ? 22 : 6, height: 6)
      }
    }
    .onAppear {
      withAnimation(Motion.resolve(Motion.bouncy).delay(Motion.reduced ? 0 : delay)) {
        grown = true
      }
    }
    .accessibilityElement()
    .accessibilityLabel(Text("Шаг \(current + 1) из \(total)"))
  }
}

/// A soft white highlight that sweeps across a primary button every few
/// seconds (the mock's `shimmer` keyframes). Place it in an overlay and clip
/// it to the button shape.
struct OnboardingShimmer: View {
  var stripWidth: CGFloat = 60
  var delay: Double = 2
  var period: Double = 3.4
  @State private var start = Date()

  var body: some View {
    Group {
      if !Motion.reduced { sweep }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var sweep: some View {
    Group {
      GeometryReader { geo in
        TimelineView(.animation) { context in
          let t = context.date.timeIntervalSince(start) - delay
          let x = offset(t, width: geo.size.width)
          LinearGradient(
            colors: [.white.opacity(0), .white.opacity(0.45), .white.opacity(0)],
            startPoint: .leading, endPoint: .trailing
          )
          .frame(width: stripWidth, height: geo.size.height)
          .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.36, d: 1, tx: 0, ty: 0))
          .offset(x: x)
          .opacity(t < 0 ? 0 : 1)
        }
      }
    }
  }

  /// Moves during the first 55% of each period (ease-in-out), then rests
  /// off the trailing edge.
  private func offset(_ t: Double, width: CGFloat) -> CGFloat {
    let from = -stripWidth * 1.4
    let to = width + stripWidth * 0.4
    guard t > 0 else { return from }
    let p = min(1, t.truncatingRemainder(dividingBy: period) / (period * 0.55))
    let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
    return from + (to - from) * eased
  }
}

/// Glass card the onboarding screens sit on, with the mock's `winIn`
/// entrance (rise, scale up, fade in).
private struct OnboardingCardModifier: ViewModifier {
  @State private var shown = false

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: Metrics.windowRadius, style: .continuous)
    content
      .background(Color.sectorCard.opacity(0.6), in: shape)
      .glassEffect(.regular, in: shape)
      .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
      .shadow(color: Color(hex: 0x141E46).opacity(0.22), radius: 40, y: 28)
      .opacity(shown ? 1 : 0)
      .scaleEffect(shown || Motion.reduced ? 1 : 0.96)
      .offset(y: shown || Motion.reduced ? 0 : 22)
      .onAppear {
        withAnimation(Motion.resolve(.spring(duration: 0.9, bounce: 0))) { shown = true }
      }
  }
}

extension View {
  func onboardingCard() -> some View { modifier(OnboardingCardModifier()) }

  /// Onboarding fills the whole window: no title and a transparent toolbar
  /// so the ambient background runs under the title bar.
  func onboardingWindowChrome() -> some View {
    self
      .toolbar(removing: .title)
      .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
  }
}

/// Continues from onboarding into the first scan.
@MainActor
func finishOnboarding(_ model: AppModel, scope: AppSettings.ScanScope) {
  guard model.phase != .main else { return }
  model.settings.scanScope = scope
  model.settings.onboarded = true
  model.startScan()
  model.phase = .main
}
