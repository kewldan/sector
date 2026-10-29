import SectorCore
import SwiftUI

/// Second onboarding step (design/mockups/Permission.dc.html): asks for
/// Full Disk Access, shows where the switch is, and continues by itself
/// once access is granted.
struct PermissionView: View {
  @Environment(AppModel.self) private var model

  @State private var demo = PermissionDemo()
  @State private var granted = false

  private static let steps: [LocalizedStringKey] = [
    "Нажмите «Открыть Настройки»",
    "Включите переключатель у Sector",
    "Вернитесь сюда — сканирование начнётся само",
  ]

  var body: some View {
    ZStack {
      AmbientBackground()
      card
    }
    .ignoresSafeArea()
    .onboardingWindowChrome()
    .task { await pollAccess() }
    .task(id: granted) {
      guard !granted else { return }
      await runDemo()
    }
    .onAppear {
      if model.hasFullDiskAccess { grant() }
    }
    .onChange(of: model.hasFullDiskAccess) { _, has in
      if has { grant() }
    }
  }

  // MARK: - Layout

  private var card: some View {
    HStack(spacing: 36) {
      VStack(alignment: .leading, spacing: 0) {
        PermissionLockBadge(open: demo.toggleOn || granted, granted: granted)
          .padding(.top, 28)

        Text("Нужен полный доступ к диску")
          .font(.system(size: 26, weight: .bold))
          .tracking(-0.5)
          .padding(.top, 18)
          .appearAnimation(delay: 0.35, offset: 14)

        Text(
          "Так Sector увидит всё, что занимает место, — включая кэши, почту и системные данные. Без вашего подтверждения ничего не удаляется."
        )
        .font(.system(size: 14))
        .lineSpacing(3)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 10)
        .appearAnimation(delay: 0.45, offset: 14)

        VStack(spacing: 6) {
          ForEach(Self.steps.indices, id: \.self) { i in
            PermissionStepRow(
              number: i + 1, text: Self.steps[i],
              highlighted: granted ? i == 2 : demo.highlightedStep == i)
          }
        }
        .padding(.top, 22)
        .appearAnimation(delay: 0.55, offset: 14)

        Spacer(minLength: 20)

        HStack(spacing: 10) {
          Button {
            model.openFullDiskAccessSettings()
          } label: {
            Text("Открыть Настройки")
              .font(.system(size: 14, weight: .semibold))
              .padding(.horizontal, 6)
          }
          .buttonStyle(.glassProminent)
          .tint(.sectorAccent)
          .controlSize(.large)
          .overlay {
            OnboardingShimmer(stripWidth: 50, delay: 1.6)
              .clipShape(.capsule)
          }
          .keyboardShortcut(.defaultAction)

          Button("Только папка пользователя") {
            finishOnboarding(model, scope: .home)
          }
          .buttonStyle(.glass)
          .controlSize(.large)
        }
        .disabled(granted)
        .appearAnimation(delay: 0.7, offset: 14)

        HStack(spacing: 8) {
          Image(systemName: "checkmark.shield")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.sectorSuccess)
          Text("Анализ идёт только на этом Mac. Данные никуда не отправляются.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(.top, 16)

        OnboardingStepDots(current: 1, delay: 0.9)
          .padding(.top, 16)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      PermissionSettingsPanel(demo: demo, granted: granted)
        .frame(width: 360)
    }
    .padding(.leading, 40)
    .padding(.trailing, 36)
    .padding(.top, 24)
    .padding(.bottom, 30)
    .frame(width: 880)
    .frame(minHeight: 540, maxHeight: 600)
    .onboardingCard()
    .padding(24)
  }

  // MARK: - Access

  /// Checks for Full Disk Access about once a second, off the main actor.
  private func pollAccess() async {
    while !Task.isCancelled && !model.hasFullDiskAccess {
      let has = await Task.detached(priority: .utility) { DiskAccess.hasFullAccess }.value
      if has {
        model.refreshDiskAccess()
        return
      }
      try? await Task.sleep(for: .seconds(1))
    }
  }

  /// Shows the switch turned on for a beat, then starts the full scan.
  private func grant() {
    guard !granted else { return }
    withAnimation(Motion.resolve(Motion.bouncy)) {
      granted = true
      demo.toggleOn = true
      demo.cursorIn = false
      demo.pressed = false
      demo.highlightedStep = nil
    }
    demo.ripple += 1
    Task {
      try? await Task.sleep(for: .seconds(0.9))
      finishOnboarding(model, scope: .startupDisk)
    }
  }

  // MARK: - Demo loop

  /// Replays the mock's 6-second loop: steps light up one by one while the
  /// cursor flips Sector's switch on and off again.
  private func runDemo() async {
    guard !Motion.reduced else {
      demo.toggleOn = true
      return
    }
    let smooth = Animation.spring(duration: 0.7, bounce: 0)
    let events: [(Double, () -> Void)] = [
      (0.0, {
        withAnimation(Motion.quick) { demo.highlightedStep = 0 }
        withAnimation(.spring(duration: 2.1, bounce: 0)) { demo.cursorIn = true }
      }),
      (1.8, { withAnimation(.easeOut(duration: 0.36)) { demo.highlightedStep = nil } }),
      (2.0, { withAnimation(Motion.quick) { demo.highlightedStep = 1 } }),
      (2.52, { withAnimation(Motion.quick) { demo.pressed = true } }),
      (2.7, {
        withAnimation(Motion.bouncy) { demo.toggleOn = true }
        withAnimation(.easeOut(duration: 0.2)) { demo.flash = true }
        demo.ripple += 1
      }),
      (2.88, { withAnimation(Motion.quick) { demo.pressed = false } }),
      (3.0, { withAnimation(.easeOut(duration: 1.2)) { demo.flash = false } }),
      (3.8, { withAnimation(.easeOut(duration: 0.36)) { demo.highlightedStep = nil } }),
      (4.0, { withAnimation(Motion.quick) { demo.highlightedStep = 2 } }),
      (4.8, { withAnimation(smooth) { demo.cursorIn = false } }),
      (5.52, { withAnimation(Motion.bouncy) { demo.toggleOn = false } }),
      (5.8, { withAnimation(.easeOut(duration: 0.36)) { demo.highlightedStep = nil } }),
    ]
    do {
      try await Task.sleep(for: .seconds(1))
      while true {
        var now = 0.0
        for (time, action) in events {
          try await Task.sleep(for: .seconds(time - now))
          now = time
          action()
        }
        try await Task.sleep(for: .seconds(6 - now))
      }
    } catch {
      // Cancelled: the view went away or access was granted.
    }
  }
}

/// State of the illustrated System Settings loop.
struct PermissionDemo: Equatable {
  var highlightedStep: Int?
  var cursorIn = false
  var pressed = false
  var toggleOn = false
  var flash = false
  var ripple = 0
}

/// Orange lock badge; the shackle opens with the switch, and the badge turns
/// green once access is granted.
private struct PermissionLockBadge: View {
  var open: Bool
  var granted: Bool
  @State private var shown = false

  var body: some View {
    let colors =
      granted
      ? [Color(hex: 0x5AD07A), Color(hex: 0x28A745)] : [Color(hex: 0xFFB340), Color(hex: 0xFF9500)]
    Image(systemName: open ? "lock.open" : "lock")
      .font(.system(size: 24, weight: .semibold))
      .foregroundStyle(.white)
      .contentTransition(.symbolEffect(.replace))
      .frame(width: 52, height: 52)
      .background(
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom),
        in: .rect(cornerRadius: 16, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(
            LinearGradient(
              colors: [.white.opacity(0.5), .white.opacity(0)], startPoint: .top,
              endPoint: .center), lineWidth: 1)
      )
      .shadow(
        color: (granted ? Color(hex: 0x28A745) : Color(hex: 0xFF9500)).opacity(0.35), radius: 10,
        y: 8)
      .scaleEffect(shown || Motion.reduced ? 1 : 0.4)
      .opacity(shown ? 1 : 0)
      .animation(Motion.resolve(Motion.smooth), value: granted)
      .onAppear {
        withAnimation(Motion.resolve(Motion.bouncy).delay(Motion.reduced ? 0 : 0.3)) {
          shown = true
        }
      }
      .accessibilityHidden(true)
  }
}

/// Numbered instruction; highlighted in turn by the demo loop.
private struct PermissionStepRow: View {
  var number: Int
  var text: LocalizedStringKey
  var highlighted: Bool

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    HStack(spacing: 12) {
      Text("\(number)")
        .font(.system(size: 12, weight: .bold))
        .monospacedDigit()
        .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .frame(width: 22, height: 22)
        .background(
          highlighted ? Color.sectorAccent : Color.primary.opacity(0.07), in: .circle)
      Text(text).font(.system(size: 13))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(highlighted ? Color.sectorAccent.opacity(0.1) : .clear, in: shape)
    .overlay(
      shape.strokeBorder(highlighted ? Color.sectorAccent.opacity(0.3) : .clear, lineWidth: 0.5))
  }
}
