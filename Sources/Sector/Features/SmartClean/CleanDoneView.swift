import SectorCore
import SwiftUI

/// Cleanup summary (design/mockups/Done.dc.html): check with ripples and
/// confetti, freed bytes, before/after and a monthly reminder toggle.
struct CleanDoneView: View {
  @Environment(AppModel.self) private var app
  let model: SmartCleanModel

  var body: some View {
    if let summary = model.summary {
      content(summary)
    } else {
      Color.clear
    }
  }

  private func content(_ summary: SmartCleanModel.Summary) -> some View {
    @Bindable var settings = app.settings
    let total = Double(max(1, summary.totalCapacity))
    return VStack(spacing: 0) {
      DoneHero()
        .frame(width: 140, height: 140)

      Text("Готово! Освобождено")
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .padding(.top, 22)
        .appearAnimation(delay: 0.5, offset: 14)
      AnimatedBytesText(
        bytes: summary.freedBytes, font: .system(size: 64, weight: .heavy), countUp: true,
        duration: 1.6, delay: 0.55
      )
      .tracking(-2.5)
      .frame(height: 72)
      .appearAnimation(delay: 0.6, offset: 14)

      VStack(spacing: 0) {
        comparisonRow(
          label: "До", bytes: summary.availableBefore, fraction: Double(summary.availableBefore) / total,
          fill: AnyShapeStyle(Color(hex: 0x8E8E93)), highlighted: false, delay: 0.9)
        comparisonRow(
          label: "После", bytes: summary.availableAfter,
          fraction: Double(summary.availableAfter) / total,
          fill: AnyShapeStyle(
            LinearGradient(
              colors: [Color(hex: 0x30B0C7), Color(hex: 0x34C759)], startPoint: .leading,
              endPoint: .trailing)),
          highlighted: true, delay: 1.2
        )
        .padding(.top, 10)

        HStack(spacing: 8) {
          chip(
            summary.objectsRemoved.formatted(),
            Plural.word(summary.objectsRemoved, "объект удалён", "объекта удалено", "объектов удалено"),
            delay: 1.3)
          chip(
            summary.categoriesCleaned.formatted(),
            Plural.word(
              summary.categoriesCleaned, "категория очищена", "категории очищено",
              "категорий очищено"),
            delay: 1.4)
          if let days = summary.daysGained {
            chip(
              "+" + Plural.format(days, "день", "дня", "дней"),
              String(localized: "до заполнения диска"), delay: 1.5)
          }
        }
        .padding(.top, 14)
      }
      .padding(.vertical, 16)
      .padding(.horizontal, 20)
      .frame(width: 520)
      .background(Color.sectorCard, in: .rect(cornerRadius: 20))
      .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.sectorHairline, lineWidth: 0.5))
      .shadow(color: .black.opacity(0.06), radius: 12, y: 8)
      .padding(.top, 22)
      .appearAnimation(delay: 0.75, offset: 14)

      HStack(spacing: 10) {
        Toggle("Напоминать о чистке раз в месяц", isOn: $settings.monthlyReminder)
          .toggleStyle(.switch)
          .labelsHidden()
        Text("Напоминать о чистке раз в месяц").font(.system(size: 13))
          .onTapGesture {
            withAnimation(Motion.resolve(Motion.bouncy)) { settings.monthlyReminder.toggle() }
          }
          .accessibilityHidden(true)
      }
      .padding(.top, 16)
      .appearAnimation(delay: 1.5, offset: 14)

      HStack(spacing: 10) {
        Button {
          model.dismissSummary(to: .history)
        } label: {
          Text("Открыть историю").font(.system(size: 14, weight: .medium)).padding(.horizontal, 6)
            .frame(height: 28)
        }
        .buttonStyle(.glass)
        Button {
          model.dismissSummary(to: .overview)
        } label: {
          Text("Готово").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 12)
            .frame(height: 28)
        }
        .buttonStyle(.glassProminent)
        .keyboardShortcut(.defaultAction)
      }
      .controlSize(.large)
      .padding(.top, 22)
      .appearAnimation(delay: 1.6, offset: 14)
    }
    .padding(.horizontal, 40)
    .padding(.vertical, 20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle("Умная очистка")
    .navigationSubtitle(String(localized: "Очистка завершена"))
  }

  private func comparisonRow(
    label: LocalizedStringKey, bytes: UInt64, fraction: Double, fill: AnyShapeStyle,
    highlighted: Bool, delay: Double
  ) -> some View {
    HStack(spacing: 10) {
      Text(label)
        .fontWeight(highlighted ? .semibold : .regular)
        .foregroundStyle(highlighted ? Color.sectorSuccess : Color.secondary)
        .frame(width: 56, alignment: .leading)
      GrowingBar(
        fraction: fraction, fill: fill, height: 10, alignment: .trailing, delay: delay,
        animation: highlighted ? Motion.bouncy : Motion.smooth)
      Text("\(ByteFormat.string(bytes)) свободно")
        .fontWeight(highlighted ? .semibold : .regular)
        .foregroundStyle(highlighted ? Color.sectorSuccess : Color.primary)
        .monospacedDigit()
        .frame(minWidth: 120, alignment: .trailing)
    }
    .font(.system(size: 12))
  }

  private func chip(_ value: String, _ caption: String, delay: Double) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(value).font(.system(size: 15, weight: .bold)).monospacedDigit()
      Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 12))
    .popIn(delay: delay)
  }
}

// MARK: - Hero

/// Green check that springs in, two ripples and a confetti burst; clicking
/// it replays the burst.
private struct DoneHero: View {
  @State private var shown = false
  @State private var drawn = false
  @State private var hovering = false
  @State private var burst = 0
  @State private var burstStart = Date()
  @State private var bursting = false

  var body: some View {
    ZStack {
      if !Motion.reduced {
        Ripple(color: Color(hex: 0x34C759).opacity(0.5), delay: 0.5).padding(10)
        Ripple(color: Color(hex: 0x30B0C7).opacity(0.4), delay: 1.0).padding(10)
        if bursting {
          Confetti(start: burstStart, colorOffset: burst.isMultiple(of: 2) ? 0 : 3)
            .allowsHitTesting(false)
        }
      }

      Button {
        guard !Motion.reduced else { return }
        burst += 1
      } label: {
        Circle()
          .fill(
            LinearGradient(
              colors: [Color(hex: 0x4CD964), Color(hex: 0x28A745)], startPoint: .top,
              endPoint: .bottom)
          )
          .overlay(alignment: .top) {
            Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1).blendMode(.plusLighter)
              .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
          }
          .overlay {
            CheckShape()
              .trim(from: 0, to: drawn ? 1 : 0)
              .stroke(.white, style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round))
              .frame(width: 64, height: 64)
          }
          .shadow(color: Color(hex: 0x28A745).opacity(0.4), radius: 20, y: 18)
          .padding(10)
          .contentShape(.circle)
      }
      .buttonStyle(HeroButtonStyle(hovering: hovering))
      .onHover { hovering = $0 }
      .accessibilityLabel("Ещё раз")
      .scaleEffect(shown ? 1 : 0)
      .rotationEffect(.degrees(shown ? 0 : -90))
    }
    .onAppear {
      if Motion.reduced {
        shown = true
        drawn = true
        return
      }
      withAnimation(.spring(duration: 0.8, bounce: 0.45).delay(0.1)) { shown = true }
      withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.6).delay(0.6)) { drawn = true }
    }
    .task(id: burst) {
      guard !Motion.reduced else { return }
      burstStart = Date()
      bursting = true
      try? await Task.sleep(for: .seconds(2.6))
      if !Task.isCancelled { bursting = false }
    }
  }
}

private struct HeroButtonStyle: ButtonStyle {
  var hovering: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.94 : hovering ? 1.05 : 1)
      .animation(Motion.resolve(Motion.bouncy), value: configuration.isPressed)
      .animation(Motion.resolve(Motion.bouncy), value: hovering)
  }
}

/// The mock's check path (M5 12.5 l4.5 4.5 L19 7.5 in a 24 grid).
private struct CheckShape: Shape {
  func path(in rect: CGRect) -> Path {
    let s = rect.width / 24
    var path = Path()
    path.move(to: CGPoint(x: 5 * s, y: 12.5 * s))
    path.addLine(to: CGPoint(x: 9.5 * s, y: 17 * s))
    path.addLine(to: CGPoint(x: 19 * s, y: 7.5 * s))
    return path
  }
}

/// Expanding ring, three times.
private struct Ripple: View {
  var color: Color
  var delay: Double
  @State private var expanded = false

  var body: some View {
    Circle()
      .strokeBorder(color, lineWidth: 2)
      .scaleEffect(expanded ? 2.2 : 0.8)
      .opacity(expanded ? 0 : 0.7)
      .onAppear {
        withAnimation(
          .timingCurve(0.2, 0.6, 0.3, 1, duration: 1.6).repeatCount(3, autoreverses: false)
            .delay(delay)
        ) { expanded = true }
      }
      .accessibilityHidden(true)
  }
}

/// 24 pieces bursting out of the check (mock `burst1…12`).
private struct Confetti: View {
  var start: Date
  var colorOffset: Int

  /// Middle and end points, middle and end rotations.
  private static let paths: [(mid: CGPoint, end: CGPoint, rotation: (Double, Double))] = [
    (CGPoint(x: 200, y: -60), CGPoint(x: 260, y: 62), (200, 420)),
    (CGPoint(x: 170, y: -150), CGPoint(x: 221, y: -55), (-180, -380)),
    (CGPoint(x: 100, y: -210), CGPoint(x: 130, y: -133), (220, 460)),
    (CGPoint(x: 20, y: -230), CGPoint(x: 26, y: -159), (-200, -400)),
    (CGPoint(x: -60, y: -215), CGPoint(x: -78, y: -140), (190, 390)),
    (CGPoint(x: -140, y: -170), CGPoint(x: -182, y: -81), (-210, -430)),
    (CGPoint(x: -200, y: -90), CGPoint(x: -260, y: 23), (180, 370)),
    (CGPoint(x: -210, y: 10), CGPoint(x: -273, y: 153), (-170, -360)),
    (CGPoint(x: -150, y: -110), CGPoint(x: -195, y: -3), (230, 470)),
    (CGPoint(x: 140, y: -100), CGPoint(x: 182, y: 10), (-220, -450)),
    (CGPoint(x: 60, y: -170), CGPoint(x: 78, y: -81), (160, 350)),
    (CGPoint(x: -30, y: -150), CGPoint(x: -39, y: -55), (-150, -340)),
  ]

  private static let colors: [Color] = [
    0x0071E3, 0x34C759, 0xFF9500, 0xFF2D55, 0x5E5CE6, 0x30B0C7, 0xFFCC00, 0xAF52DE,
  ].map { Color(hex: $0) }

  private static let curve = UnitCurve.bezier(
    startControlPoint: UnitPoint(x: 0.15, y: 0.7), endControlPoint: UnitPoint(x: 0.3, y: 1))

  var body: some View {
    TimelineView(.animation) { context in
      let elapsed = context.date.timeIntervalSince(start)
      ZStack {
        ForEach(0..<24, id: \.self) { i in
          piece(i, elapsed: elapsed)
        }
      }
    }
    .accessibilityHidden(true)
  }

  @ViewBuilder private func piece(_ i: Int, elapsed: Double) -> some View {
    let path = Self.paths[i % 12]
    let round = i % 3 == 0
    let duration = 1.4 + Double(i % 4) * 0.15
    let delay = 0.35 + (i >= 12 ? 0.12 : 0)
    let p = min(1, max(0, (elapsed - delay) / duration))
    let x = Keyframes(stops: [(0, 0), (0.5, path.mid.x), (1, path.end.x)], curve: Self.curve)
    let y = Keyframes(stops: [(0, 0), (0.5, path.mid.y), (1, path.end.y)], curve: Self.curve)
    let angle = Keyframes(
      stops: [(0, 0), (0.5, path.rotation.0), (1, path.rotation.1)], curve: Self.curve)
    let scale = Keyframes(stops: [(0, 0.3), (0.5, 1), (1, 0.9)], curve: Self.curve)
    let opacity = Keyframes(stops: [(0, 1), (0.5, 1), (1, 0)], curve: Self.curve)
    RoundedRectangle(cornerRadius: round ? 4 : 2)
      .fill(Self.colors[(i + colorOffset) % Self.colors.count])
      .frame(width: round ? 8 : 7, height: round ? 8 : 13)
      .scaleEffect(scale.value(at: p))
      .rotationEffect(.degrees(angle.value(at: p)))
      .offset(x: x.value(at: p), y: y.value(at: p))
      .opacity(opacity.value(at: p))
  }
}
