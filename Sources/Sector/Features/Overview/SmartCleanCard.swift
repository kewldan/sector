import SectorCore
import SwiftUI

/// Blue Smart Clean teaser with the reclaimable total; opens Smart Clean.
struct OverviewSmartCleanCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let smartClean = model.smartClean
    let bytes = smartClean.reclaimableBytes
    Button {
      model.route = .smartClean
    } label: {
      ZStack(alignment: .topLeading) {
        LinearGradient(
          colors: [Color(hex: 0x0071E3), Color(hex: 0x4B4FD9)], startPoint: .topLeading,
          endPoint: .bottomTrailing)
        SmartCleanDecor()

        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 7) {
            Image(systemName: "sparkle")
              .font(.system(size: 14, weight: .semibold))
              .symbolEffect(.breathe, options: .repeat(.continuous), isActive: !Motion.reduced)
            Text("Умная очистка")
          }
          .font(.system(size: 13, weight: .semibold))
          .opacity(0.95)

          Group {
            if smartClean.isAnalyzing && bytes == 0 {
              Text("Анализ…")
            } else {
              CountingByteText(bytes: bytes, delay: 0.35)
            }
          }
          .font(.system(size: 38, weight: .bold))
          .tracking(-1)
          .padding(.top, 8)

          Text(subtitle(bytes: bytes, analyzing: smartClean.isAnalyzing))
            .font(.system(size: 13))
            .opacity(0.88)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)

        ReviewPill()
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
          .padding(.trailing, 20)
          .padding(.bottom, 18)
      }
      .foregroundStyle(.white)
      .clipShape(.rect(cornerRadius: Metrics.cardRadius))
      .overlay(
        RoundedRectangle(cornerRadius: Metrics.cardRadius)
          .strokeBorder(
            LinearGradient(
              colors: [.white.opacity(0.35), .white.opacity(0)], startPoint: .top,
              endPoint: .center), lineWidth: 1)
      )
      .shadow(color: Color(hex: 0x005AC8).opacity(0.28), radius: 15, y: 10)
      .contentShape(.rect(cornerRadius: Metrics.cardRadius))
    }
    .buttonStyle(PressScaleStyle())
    .hoverLift()
    .accessibilityLabel(Text("Умная очистка, \(ByteFormat.string(bytes))"))
  }

  private func subtitle(bytes: UInt64, analyzing: Bool) -> LocalizedStringKey {
    if bytes > 0 { return "можно освободить без риска" }
    return analyzing ? "ищем, что можно удалить" : "сейчас нечего чистить"
  }
}

/// White "Просмотреть ›" pill with a passing shimmer.
private struct ReviewPill: View {
  var body: some View {
    HStack(spacing: 6) {
      Text("Просмотреть")
      Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
    }
    .font(.system(size: 13, weight: .semibold))
    .foregroundStyle(Color(hex: 0x0062C4))
    .padding(.horizontal, 16)
    .frame(height: 34)
    .background {
      Capsule().fill(.white.opacity(0.92))
        .overlay {
          if !Motion.reduced {
            CardShimmer().clipShape(.capsule)
          }
        }
    }
    .shadow(color: Color(hex: 0x001E5A).opacity(0.2), radius: 7, y: 4)
  }
}

private struct CardShimmer: View {
  var body: some View {
    GeometryReader { geo in
      LinearGradient(
        colors: [
          Color(hex: 0x0071E3).opacity(0), Color(hex: 0x0071E3).opacity(0.18),
          Color(hex: 0x0071E3).opacity(0),
        ],
        startPoint: .leading, endPoint: .trailing
      )
      .frame(width: 30)
      .rotationEffect(.degrees(20))
      .keyframeAnimator(initialValue: -40.0, repeating: true) { content, x in
        content.offset(x: x)
      } keyframes: { _ in
        LinearKeyframe(-40.0, duration: 1.5)
        LinearKeyframe(Double(geo.size.width) + 20, duration: 1.65, timingCurve: .easeInOut)
        LinearKeyframe(Double(geo.size.width) + 20, duration: 1.35)
      }
    }
    .allowsHitTesting(false)
  }
}

/// Rising bubbles and a slowly turning sparkle behind the card content.
private struct SmartCleanDecor: View {
  @State private var spin = false

  private struct Bubble {
    var x: CGFloat
    var size: CGFloat
    var opacity: Double
    var duration: Double
    var delay: Double
  }

  private let bubbles: [Bubble] = [
    .init(x: 0.62, size: 8, opacity: 0.7, duration: 4, delay: 0),
    .init(x: 0.78, size: 5, opacity: 0.6, duration: 3.2, delay: 1.1),
    .init(x: 0.88, size: 10, opacity: 0.45, duration: 4.6, delay: 2),
    .init(x: 0.70, size: 4, opacity: 0.8, duration: 3.6, delay: 2.6),
  ]

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .topLeading) {
        Image(systemName: "sparkle")
          .font(.system(size: 130, weight: .ultraLight))
          .foregroundStyle(.white.opacity(0.13))
          .rotationEffect(.degrees(spin ? 360 : 0))
          .position(x: geo.size.width - 55, y: 49)
        if !Motion.reduced {
          ForEach(bubbles.indices, id: \.self) { i in
            let b = bubbles[i]
            Circle()
              .fill(.white.opacity(b.opacity))
              .frame(width: b.size, height: b.size)
              .keyframeAnimator(initialValue: BubbleState(), repeating: true) { content, s in
                content.scaleEffect(s.scale).opacity(s.opacity).offset(y: s.y)
              } keyframes: { _ in
                KeyframeTrack(\.y) {
                  LinearKeyframe(0, duration: b.delay)
                  LinearKeyframe(-130, duration: b.duration, timingCurve: .easeOut)
                }
                KeyframeTrack(\.scale) {
                  LinearKeyframe(1, duration: b.delay)
                  LinearKeyframe(0.4, duration: b.duration, timingCurve: .easeOut)
                }
                KeyframeTrack(\.opacity) {
                  LinearKeyframe(0, duration: b.delay)
                  LinearKeyframe(0.9, duration: b.duration * 0.15)
                  LinearKeyframe(0, duration: b.duration * 0.85)
                }
              }
              .position(x: geo.size.width * b.x, y: geo.size.height + 6)
          }
        }
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .onAppear {
      guard !Motion.reduced else { return }
      withAnimation(.linear(duration: 40).repeatForever(autoreverses: false)) { spin = true }
    }
  }
}

private struct BubbleState {
  var y: Double = 0
  var scale: Double = 1
  var opacity: Double = 0
}

/// Slight press-down for card-sized buttons.
private struct PressScaleStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .animation(Motion.resolve(Motion.quick), value: configuration.isPressed)
  }
}
