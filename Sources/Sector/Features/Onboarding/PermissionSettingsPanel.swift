import SectorCore
import SwiftUI

/// Illustration of System Settings › Privacy & Security › Full Disk Access,
/// with a cursor turning on Sector's switch (driven by `PermissionDemo`).
/// Decorative: hidden from accessibility.
struct PermissionSettingsPanel: View {
  var demo: PermissionDemo
  var granted: Bool
  @State private var shown = false

  private static let panelFill = Color(light: 0xFFFFFF, dark: 0x2B2C31)

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        dot(0xFF5F57)
        dot(0xFEBC2E)
        dot(0x28C840)
        Text("Конфиденциальность и безопасность")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .padding(.leading, 10)
      }
      .padding(.horizontal, 4)
      .padding(.top, 2)
      .padding(.bottom, 12)

      Text("Полный доступ к диску")
        .font(.system(size: 15, weight: .bold))
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
      Text("Разрешите приложениям доступ к данным на этом Mac.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.bottom, 12)

      list

      HStack(spacing: 6) {
        smallButton("+")
        smallButton("−")
      }
      .padding(.horizontal, 4)
      .padding(.top, 12)
      .padding(.bottom, 2)
    }
    .padding(14)
    .background(Self.panelFill.opacity(0.8), in: shape)
    .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    .shadow(color: Color(hex: 0x141E46).opacity(0.18), radius: 30, y: 24)
    .opacity(shown ? 1 : 0)
    .offset(x: shown || Motion.reduced ? 0 : 30)
    .rotation3DEffect(
      .degrees(shown || Motion.reduced ? 0 : -12), axis: (x: 0, y: 1, z: 0), perspective: 0.6
    )
    .onAppear {
      let entrance = Motion.resolve(.spring(duration: 1, bounce: 0))
      withAnimation(entrance.delay(Motion.reduced ? 0 : 0.45)) { shown = true }
    }
    .accessibilityHidden(true)
  }

  private var list: some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    return VStack(spacing: 0) {
      PermissionAppRow(name: "Терминал", isOn: true) {
        Text(">_")
          .font(.system(size: 10, weight: .semibold, design: .monospaced))
          .foregroundStyle(Color(hex: 0x34C759))
          .frame(width: 26, height: 26)
          .background(
            LinearGradient(
              colors: [Color(hex: 0x3A3A3C), Color(hex: 0x1C1C1E)], startPoint: .top,
              endPoint: .bottom),
            in: .rect(cornerRadius: 7, style: .continuous))
      }
      separator
      sectorRow
        .zIndex(1)
      separator
      PermissionAppRow(name: "Резервное копирование", isOn: true) {
        Image(systemName: "arrow.counterclockwise")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 26, height: 26)
          .background(
            LinearGradient(
              colors: [Color(hex: 0x5AD07A), Color(hex: 0x28A745)], startPoint: .top,
              endPoint: .bottom),
            in: .rect(cornerRadius: 7, style: .continuous))
      }
      separator
      PermissionAppRow(name: "Помощник синхронизации", isOn: false, dimmed: true) {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(
            LinearGradient(
              colors: [Color(hex: 0xB4B4BA), Color(hex: 0x8E8E93)], startPoint: .top,
              endPoint: .bottom)
          )
          .frame(width: 26, height: 26)
      }
    }
    .background(Color.primary.opacity(0.035), in: shape)
    .overlay(shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    .clipShape(shape)
  }

  private var sectorRow: some View {
    PermissionAppRow(name: "Sector", isOn: demo.toggleOn, bold: true, ripple: demo.ripple) {
      OnboardingAppIcon(size: 26, arc: 0.62, detailed: false)
    }
    .background(Color(hex: 0x34C759, opacity: demo.flash ? 0.16 : 0))
    .overlay(alignment: .topTrailing) {
      PermissionCursor()
        .frame(width: 22, height: 26)
        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 2)
        .scaleEffect(demo.pressed ? 0.82 : 1, anchor: .topLeading)
        .offset(x: demo.cursorIn ? -6 : -126, y: demo.cursorIn ? 20 : 170)
        .opacity(granted ? 0 : 1)
    }
  }

  private var separator: some View {
    Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5)
  }

  private func dot(_ hex: UInt32) -> some View {
    Circle().fill(Color(hex: hex)).frame(width: 9, height: 9)
  }

  private func smallButton(_ label: String) -> some View {
    Text(verbatim: label)
      .font(.system(size: 14))
      .foregroundStyle(.secondary)
      .frame(width: 22, height: 20)
      .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 5))
  }
}

/// App row with an icon, a name and a System Settings style switch.
private struct PermissionAppRow<Icon: View>: View {
  var name: LocalizedStringKey
  var isOn: Bool
  var bold = false
  var dimmed = false
  var ripple = 0
  @ViewBuilder var icon: Icon

  var body: some View {
    HStack(spacing: 10) {
      icon
      Text(name)
        .font(.system(size: 13, weight: bold ? .semibold : .regular))
        .foregroundStyle(dimmed ? .secondary : .primary)
        .frame(maxWidth: .infinity, alignment: .leading)
      PermissionSwitch(isOn: isOn, ripple: ripple)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }
}

/// 36×20 switch; a green ripple spreads when `ripple` changes.
private struct PermissionSwitch: View {
  var isOn: Bool
  var ripple: Int

  private enum RipplePhase: CaseIterable { case idle, start, spread }

  var body: some View {
    ZStack(alignment: .leading) {
      Capsule().fill(isOn ? Color(hex: 0x34C759) : Color.primary.opacity(0.14))
      Circle()
        .fill(.white)
        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
        .frame(width: 16, height: 16)
        .offset(x: isOn ? 18 : 2)
    }
    .frame(width: 36, height: 20)
    .background {
      Ellipse()
        .fill(Color(hex: 0x34C759, opacity: 0.5))
        .frame(width: 60, height: 48)
        .phaseAnimator(RipplePhase.allCases, trigger: ripple) { content, phase in
          content
            .scaleEffect(phase == .idle ? 0 : phase == .start ? 0.3 : 1.6)
            .opacity(phase == .start ? 0.6 : 0)
        } animation: { phase in
          switch phase {
          case .idle: .linear(duration: 0.01)
          case .start: .linear(duration: 0.08)
          case .spread: .easeOut(duration: 0.96)
          }
        }
        .opacity(Motion.reduced ? 0 : 1)
    }
  }
}

/// The macOS arrow pointer from the mock (22×26 box).
private struct PermissionCursor: View {
  var body: some View {
    PermissionCursorShape()
      .fill(.white)
      .overlay(
        PermissionCursorShape()
          .stroke(.black, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round)))
  }
}

private struct PermissionCursorShape: Shape {
  func path(in rect: CGRect) -> Path {
    let sx = rect.width / 22
    let sy = rect.height / 26
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy)
    }
    var path = Path()
    path.move(to: p(2, 2))
    path.addLine(to: p(2, 21))
    path.addLine(to: p(7, 16.5))
    path.addLine(to: p(10.4, 23.9))
    path.addLine(to: p(13.6, 22.4))
    path.addLine(to: p(10.3, 15.2))
    path.addLine(to: p(17, 15.2))
    path.closeSubpath()
    return path
  }
}
