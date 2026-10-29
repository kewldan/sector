import SectorCore
import SwiftUI

/// First onboarding step (design/mockups/Main.dc.html): the animated app
/// icon, what Sector does, and "Продолжить" to the permission step.
struct WelcomeView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    ZStack {
      AmbientBackground()
      card
    }
    .ignoresSafeArea()
    .onboardingWindowChrome()
  }

  private var card: some View {
    VStack(spacing: 0) {
      WelcomeHero()
        .padding(.top, 4)

      Text("Добро пожаловать в Sector")
        .font(.system(size: 30, weight: .bold))
        .tracking(-0.6)
        .multilineTextAlignment(.center)
        .padding(.top, 14)
        .appearAnimation(delay: 0.35, offset: 14)

      Text(
        "Узнайте, что занимает место на вашем Mac, и освободите его — безопасно, наглядно и за пару кликов."
      )
      .font(.system(size: 14))
      .lineSpacing(3)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 440)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 10)
      .appearAnimation(delay: 0.45, offset: 14)

      HStack(spacing: 12) {
        WelcomeFeatureTile(
          symbol: "chart.pie", color: .sectorAccent, title: "Карта диска",
          text: Text("Каждая папка — сегмент. Видно, где лишнее."))
        .appearAnimation(delay: 0.6, offset: 14)
        WelcomeFeatureTile(
          symbol: "sparkles", color: Color(hex: 0x5E5CE6), title: "Умная очистка",
          text: Text("Кэши, сборки, старые загрузки — одним списком."))
        .appearAnimation(delay: 0.7, offset: 14)
        WelcomeFeatureTile(
          symbol: "checkmark.shield", color: .sectorSuccess, title: "Можно вернуть",
          text: restoreText)
        .appearAnimation(delay: 0.8, offset: 14)
      }
      .fixedSize(horizontal: false, vertical: true)
      .padding(.top, 26)

      Spacer(minLength: 24)

      Button {
        model.refreshDiskAccess()
        model.phase = .permission
      } label: {
        Text("Продолжить")
          .font(.system(size: 15, weight: .semibold))
          .frame(width: 248, height: 30)
      }
      .buttonStyle(.glassProminent)
      .tint(.sectorAccent)
      .controlSize(.extraLarge)
      .overlay {
        OnboardingShimmer(stripWidth: 60, delay: 2)
          .clipShape(.capsule)
      }
      .keyboardShortcut(.defaultAction)
      .appearAnimation(delay: 0.95, offset: 14)

      OnboardingStepDots(current: 0, delay: 1.1)
        .padding(.top, 16)
    }
    .padding(.horizontal, 48)
    .padding(.top, 24)
    .padding(.bottom, 28)
    .frame(width: 640)
    .frame(minHeight: 560, maxHeight: 620)
    .onboardingCard()
    .padding(24)
  }

  private var restoreText: Text {
    let days = Plural.format(model.settings.keepDays, "день", "дня", "дней")
    return Text("Всё уходит в Корзину, история хранит \(days).")
  }
}

/// Icon with pulse rings, two slowly counter-rotating dotted orbits and a
/// gentle float; the icon springs in and its arc draws on appear.
private struct WelcomeHero: View {
  @State private var start = Date()
  @State private var iconIn = false
  @State private var arc = 0.0

  private static let ringColors: [Color] = [
    Color(hex: 0x0071E3, opacity: 0.35), Color(hex: 0x5E5CE6, opacity: 0.3),
    Color(hex: 0x30B0C7, opacity: 0.3),
  ]

  var body: some View {
    let reduced = Motion.reduced
    TimelineView(.animation(minimumInterval: nil, paused: reduced)) { context in
      let t = reduced ? 0 : context.date.timeIntervalSince(start)
      ZStack {
        if !reduced {
          ForEach(0..<3, id: \.self) { i in
            let p = pulse(t - Double(i) * 1.066)
            Circle()
              .strokeBorder(Self.ringColors[i], lineWidth: 1.5)
              .scaleEffect(0.72 + 0.78 * p)
              .opacity(t < Double(i) * 1.066 ? 0 : 0.75 * (1 - p))
          }
        }
        outerOrbit.rotationEffect(.degrees(t / 24 * 360))
        innerOrbit.rotationEffect(.degrees(-t / 16 * 360))
        icon(t)
      }
      .frame(width: 210, height: 210)
    }
    .frame(width: 210, height: 210)
    .accessibilityElement()
    .accessibilityLabel(Text("Иконка приложения Sector"))
    .onAppear {
      withAnimation(Motion.resolve(.spring(duration: 1.1, bounce: 0.45)).delay(reduced ? 0 : 0.2)) {
        iconIn = true
      }
      withAnimation(Motion.resolve(.spring(duration: 1.6, bounce: 0)).delay(reduced ? 0 : 0.7)) {
        arc = 0.62
      }
    }
  }

  private func icon(_ t: Double) -> some View {
    // Float starts once the entrance settles.
    let f = t > 1.3 ? (1 - cos((t - 1.3) / 5 * 2 * .pi)) / 2 : 0
    return OnboardingAppIcon(size: 128, arc: arc)
      .shadow(color: Color(hex: 0x0050C8, opacity: 0.35), radius: 15, y: 18)
      .rotationEffect(.degrees(-2 * f))
      .offset(y: -9 * f)
      .scaleEffect(iconIn ? 1 : 0.4)
      .rotationEffect(.degrees(iconIn ? 0 : -30))
      .opacity(iconIn ? 1 : 0)
  }

  /// 0...1 progress of a 3.2 s pulse with an ease-out curve.
  private func pulse(_ t: Double) -> Double {
    guard t > 0 else { return 0 }
    let p = t.truncatingRemainder(dividingBy: 3.2) / 3.2
    return 1 - pow(1 - p, 2.4)
  }

  private var outerOrbit: some View {
    ZStack {
      Circle()
        .stroke(
          Color(hex: 0x0071E3, opacity: 0.28),
          style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 7]))
        .frame(width: 184, height: 184)
      Circle().fill(Color(hex: 0x0071E3)).frame(width: 8, height: 8).offset(y: -92)
    }
    .frame(width: 200, height: 200)
  }

  private var innerOrbit: some View {
    ZStack {
      Circle()
        .stroke(Color(hex: 0x5E5CE6, opacity: 0.22), lineWidth: 1)
        .frame(width: 160, height: 160)
      Circle().fill(Color(hex: 0x5E5CE6)).frame(width: 7, height: 7).offset(y: 80)
      Circle().fill(Color(hex: 0x30B0C7)).frame(width: 5, height: 5).offset(x: -80)
    }
    .frame(width: 170, height: 170)
  }
}

/// One of the three feature tiles; lifts slightly on hover.
private struct WelcomeFeatureTile: View {
  var symbol: String
  var color: Color
  var title: LocalizedStringKey
  var text: Text
  @State private var hovered = false
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    VStack(spacing: 8) {
      Image(systemName: symbol)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(color)
        .frame(width: 36, height: 36)
        .background(color.opacity(0.13), in: .circle)
      Text(title).font(.system(size: 13, weight: .semibold))
      text
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .lineSpacing(1)
        .fixedSize(horizontal: false, vertical: true)
    }
    .multilineTextAlignment(.center)
    .padding(.vertical, 16)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.sectorCard, in: shape)
    .background(
      hovered ? Color.white.opacity(scheme == .dark ? 0.05 : 0.5) : .clear, in: shape)
    .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    .offset(y: hovered && !Motion.reduced ? -3 : 0)
    .onHover { hovering in
      withAnimation(Motion.resolve(.spring(duration: 0.35, bounce: 0))) { hovered = hovering }
    }
    .accessibilityElement(children: .combine)
  }
}
