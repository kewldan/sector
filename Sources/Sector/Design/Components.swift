import SectorCore
import SwiftUI

// Shared building blocks. Screens compose these instead of restyling
// cards, badges and numbers on their own, so the app reads as one system.

/// Rounded content card on the window background.
struct Card<Content: View>: View {
  var padding: CGFloat = Metrics.cardPadding
  var radius: CGFloat = Metrics.cardRadius
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.sectorCard, in: .rect(cornerRadius: radius))
      .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.sectorHairline, lineWidth: 0.5))
      .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
  }
}

/// Screen header: title, subtitle and trailing controls.
struct PageHeader<Trailing: View>: View {
  var title: LocalizedStringKey
  var subtitle: String?
  @ViewBuilder var trailing: Trailing

  init(_ title: LocalizedStringKey, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
    self.title = title
    self.subtitle = subtitle
    self.trailing = trailing()
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.sectorSection)
        if let subtitle {
          Text(subtitle).font(.sectorBody).foregroundStyle(.secondary)
            .contentTransition(.numericText())
        }
      }
      Spacer(minLength: 12)
      trailing
    }
  }
}

extension PageHeader where Trailing == EmptyView {
  init(_ title: LocalizedStringKey, subtitle: String? = nil) {
    self.init(title, subtitle: subtitle) { EmptyView() }
  }
}

/// Tinted rounded square with an SF Symbol, as in sidebar and list rows.
struct IconBadge: View {
  var symbol: String
  var color: Color
  var size: CGFloat = 28

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.5, weight: .medium))
      .foregroundStyle(color)
      .frame(width: size, height: size)
      .background(color.opacity(0.14), in: .rect(cornerRadius: size * 0.3))
  }
}

/// File-type badge for file rows ("MOV", "PVM").
struct FileKindBadge: View {
  var label: String
  var color: Color = .secondary
  var size: CGFloat = 34

  var body: some View {
    Text(label)
      .font(.system(size: size * 0.27, weight: .bold, design: .rounded))
      .foregroundStyle(color)
      .frame(width: size, height: size)
      .background(color.opacity(0.12), in: .rect(cornerRadius: size * 0.28))
  }
}

/// Safety label on cleanup items.
struct SafetyBadge: View {
  enum Kind { case safe, review, irreversible }
  var kind: Kind

  var body: some View {
    let (text, color): (LocalizedStringKey, Color) =
      switch kind {
      case .safe: ("Безопасно", .sectorSuccess)
      case .review: ("Проверьте", .sectorWarning)
      case .irreversible: ("Необратимо", .sectorDanger)
      }
    Text(text)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 2)
      .background(color.opacity(0.13), in: .capsule)
  }
}

/// Byte size with tabular digits; animates digit changes.
struct SizeText: View {
  var bytes: UInt64
  var font: Font = .sectorBody

  var body: some View {
    Text(ByteFormat.string(bytes))
      .font(font)
      .monospacedDigit()
      .contentTransition(.numericText(value: Double(bytes)))
  }
}

/// Counts a byte value up from zero (or from its previous value) with the
/// design's ease-out counter. Number and unit can be styled apart.
struct CountingBytes: View {
  var bytes: UInt64
  var numberFont: Font = .sectorHero
  var unitFont: Font = .system(size: 20, weight: .semibold)
  var unitColor: Color = .secondary
  /// Start from zero on first appearance.
  var countUpOnAppear = true

  @State private var shown: Double = 0

  var body: some View {
    Color.clear.frame(width: 0, height: 0)
      .modifier(
        CountingBytesModifier(
          value: shown, numberFont: numberFont, unitFont: unitFont, unitColor: unitColor)
      )
      .onAppear {
        if !countUpOnAppear || Motion.reduced {
          shown = Double(bytes)
        } else {
          withAnimation(Motion.counter) { shown = Double(bytes) }
        }
      }
      .onChange(of: bytes) { _, new in
        withAnimation(Motion.resolve(Motion.counter)) { shown = Double(new) }
      }
  }
}

private struct CountingBytesModifier: ViewModifier, Animatable {
  var value: Double
  var numberFont: Font
  var unitFont: Font
  var unitColor: Color

  nonisolated var animatableData: Double {
    get { value }
    set { value = newValue }
  }

  func body(content: Content) -> some View {
    let parts = ByteFormat.parts(UInt64(max(0, value)))
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(parts.number).font(numberFont).monospacedDigit()
      Text(parts.unit).font(unitFont).foregroundStyle(unitColor)
    }
  }
}

/// Circular progress ring with a rounded cap.
struct ProgressRing: View {
  var fraction: Double
  var lineWidth: CGFloat = 10
  var color: Color = .sectorAccent
  var track: Color = .sectorTrack

  var body: some View {
    ZStack {
      Circle().stroke(track, lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: max(0.001, min(1, fraction)))
        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
    }
    .padding(lineWidth / 2)
  }
}

/// Horizontal stacked bar of category shares.
struct SegmentedBar: View {
  struct Segment: Identifiable {
    var id: String
    var value: Double
    var color: Color
  }

  var segments: [Segment]
  var total: Double
  var height: CGFloat = 10
  var highlighted: String?

  var body: some View {
    GeometryReader { geo in
      HStack(spacing: 2) {
        ForEach(segments) { s in
          Rectangle()
            .fill(s.color)
            .opacity(highlighted == nil || highlighted == s.id ? 1 : 0.3)
            .frame(width: max(2, geo.size.width * s.value / max(total, 1) - 2))
        }
        Spacer(minLength: 0)
      }
    }
    .frame(height: height)
    .background(Color.sectorTrack)
    .clipShape(.capsule)
    .animation(Motion.quick, value: highlighted)
  }
}

/// Round checkbox used in selectable lists; bounces when toggled.
struct SelectionCheck: View {
  var isOn: Bool
  var color: Color = .sectorAccent
  var size: CGFloat = 20

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.32)
        .fill(isOn ? color : Color.clear)
        .overlay(
          RoundedRectangle(cornerRadius: size * 0.32)
            .strokeBorder(isOn ? Color.clear : Color.primary.opacity(0.25), lineWidth: 1))
      Image(systemName: "checkmark")
        .font(.system(size: size * 0.55, weight: .bold))
        .foregroundStyle(.white)
        .scaleEffect(isOn ? 1 : 0.3)
        .opacity(isOn ? 1 : 0)
    }
    .frame(width: size, height: size)
    .shadow(color: isOn ? color.opacity(0.35) : .clear, radius: 3, y: 1)
    .animation(Motion.resolve(Motion.bouncy), value: isOn)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/// Placeholder for empty lists and missing data.
struct EmptyStateView<Actions: View>: View {
  var symbol: String
  var title: LocalizedStringKey
  var message: LocalizedStringKey
  @ViewBuilder var actions: Actions

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 40, weight: .light))
        .foregroundStyle(.secondary)
        .symbolRenderingMode(.hierarchical)
      Text(title).font(.sectorSection)
      Text(message).font(.sectorBody).foregroundStyle(.secondary)
        .multilineTextAlignment(.center).frame(maxWidth: 360)
      actions.padding(.top, 4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(40)
  }
}

extension EmptyStateView where Actions == EmptyView {
  init(symbol: String, title: LocalizedStringKey, message: LocalizedStringKey) {
    self.init(symbol: symbol, title: title, message: message) { EmptyView() }
  }
}

extension View {
  /// Fades and lifts the view in after `delay`, like the mock's `fadeUp`.
  func appearAnimation(delay: Double = 0, offset: CGFloat = 12) -> some View {
    modifier(AppearModifier(delay: delay, offset: offset))
  }

  /// Uppercased caption label ("ИНСТРУМЕНТЫ").
  func sectionLabelStyle() -> some View {
    font(.sectorCaption).textCase(.uppercase).foregroundStyle(.secondary).tracking(0.4)
  }
}

private struct AppearModifier: ViewModifier {
  var delay: Double
  var offset: CGFloat
  @State private var visible = false

  func body(content: Content) -> some View {
    content
      .opacity(visible ? 1 : 0)
      .offset(y: visible || Motion.reduced ? 0 : offset)
      .onAppear {
        withAnimation(Motion.resolve(Motion.smooth).delay(Motion.reduced ? 0 : delay)) {
          visible = true
        }
      }
  }
}

/// Soft drifting color fields behind the window content, as in the mocks.
struct AmbientBackground: View {
  @Environment(\.colorScheme) private var scheme
  @State private var drift = false

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let h = geo.size.height
      ZStack {
        blob(Color(hex: 0x3884FF), size: w * 0.7)
          .offset(x: -w * 0.35 + (drift ? 60 : 0), y: -h * 0.4 + (drift ? 40 : 0))
        blob(Color(hex: 0xAF52DE), size: w * 0.75)
          .offset(x: w * 0.4 - (drift ? 70 : 0), y: h * 0.45 - (drift ? 50 : 0))
        blob(Color(hex: 0x30B0C7), size: w * 0.5)
          .offset(x: w * 0.05 - (drift ? 40 : 0), y: h * 0.25 + (drift ? 30 : 0))
      }
      .frame(width: w, height: h)
    }
    .opacity(scheme == .dark ? 0.35 : 0.55)
    .background(scheme == .dark ? Color(hex: 0x16171C) : Color(hex: 0xEEF2F9))
    .ignoresSafeArea()
    .onAppear {
      guard !Motion.reduced else { return }
      withAnimation(.easeInOut(duration: 24).repeatForever(autoreverses: true)) { drift = true }
    }
    .accessibilityHidden(true)
  }

  private func blob(_ color: Color, size: CGFloat) -> some View {
    Circle()
      .fill(RadialGradient(colors: [color.opacity(0.5), color.opacity(0)], center: .center, startRadius: 0, endRadius: size / 2))
      .frame(width: size, height: size)
  }
}
