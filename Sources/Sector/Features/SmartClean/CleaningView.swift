import SectorCore
import SwiftUI

/// Cleanup in progress (design/mockups/Cleaning.dc.html): ring with the
/// freed counter, per-category rows going pending → active → done.
struct CleaningView: View {
  let model: SmartCleanModel

  var body: some View {
    if let run = model.run {
      content(run)
    } else {
      Color.clear
    }
  }

  private func content(_ run: SmartCleanModel.Run) -> some View {
    let running = !run.isFinished && !run.isPaused
    return HStack(spacing: 40) {
      VStack(spacing: 0) {
        CleaningRing(run: run, running: running)
          .frame(width: 280, height: 280)
        ProgressStrip(fraction: run.fraction, running: running)
          .frame(width: 260, height: 6)
          .padding(.top, 26)
        Text(statusLine(run))
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .contentTransition(.numericText())
          .padding(.top, 10)
        if run.isFinished, run.result?.outcome.failed.isEmpty == false {
          let failed = run.result?.outcome.failed.count ?? 0
          Text("Не удалось удалить: \(Plural.format(failed, "объект", "объекта", "объектов"))")
            .font(.system(size: 11))
            .foregroundStyle(Color.sectorWarning)
            .padding(.top, 4)
        }
        if run.isFinished {
          Button {
            model.showSummary()
          } label: {
            Label("Посмотреть итог", systemImage: "chevron.right")
              .labelStyle(TrailingIconLabelStyle())
              .font(.system(size: 14, weight: .semibold))
              .padding(.horizontal, 12)
              .frame(height: 28)
          }
          .buttonStyle(.glassProminent)
          .controlSize(.large)
          .keyboardShortcut(.defaultAction)
          .padding(.top, 18)
          .appearAnimation(delay: 0.3)
        }
      }
      .frame(width: 340)

      StepList(run: run)
        .frame(maxWidth: .infinity)
    }
    .padding(.leading, 40)
    .padding(.trailing, 36)
    .padding(.bottom, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(Motion.resolve(Motion.smooth), value: run.isFinished)
    .navigationTitle(title(run))
    .navigationSubtitle(subtitle(run))
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        if run.isPaused {
          Button("Завершить") { model.stop() }
          Button {
            model.resume()
          } label: {
            Text("Продолжить").fontWeight(.semibold).foregroundStyle(Color.sectorAccent)
          }
        } else if !run.isFinished {
          Button("Остановить") { model.pause() }
        }
      }
    }
  }

  private func title(_ run: SmartCleanModel.Run) -> String {
    if run.isFinished {
      return run.result?.wasCancelled == true
        ? String(localized: "Очистка остановлена") : String(localized: "Очистка завершена")
    }
    return run.isPaused ? String(localized: "Очистка на паузе") : String(localized: "Идёт очистка")
  }

  private func subtitle(_ run: SmartCleanModel.Run) -> String {
    guard run.isFinished else { return String(localized: "Не выключайте Mac · можно продолжать работать") }
    let done = run.progress.steps.filter { $0.state == .done }.count
    if done == run.steps.count {
      return done == 1
        ? String(localized: "Категория обработана")
        : String(localized: "Все \(Plural.format(done, "категория", "категории", "категорий")) обработаны")
    }
    return String(
      localized: "Обработано \(done) из \(Plural.format(run.steps.count, "категории", "категорий", "категорий"))")
  }

  private func statusLine(_ run: SmartCleanModel.Run) -> String {
    if run.isFinished {
      let seconds = Int(run.result?.duration.rounded() ?? 0)
      return seconds < 1
        ? String(localized: "Заняло меньше секунды")
        : String(localized: "Заняло \(Plural.format(seconds, "секунду", "секунды", "секунд"))")
    }
    let percent = Int(run.fraction * 100)
    if run.isPaused { return String(localized: "Пауза · \(percent)%") }
    guard let remaining = run.remaining else { return "\(percent)%" }
    let left =
      remaining < 60
      ? String(localized: "\(Int(remaining.rounded(.up))) с")
      : String(localized: "\(Int((remaining / 60).rounded(.up))) мин")
    return String(localized: "\(percent)% · осталось ~\(left)")
  }
}

private struct TrailingIconLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.title
      configuration.icon.font(.system(size: 11, weight: .bold))
    }
  }
}

// MARK: - Ring

private struct CleaningRing: View {
  let run: SmartCleanModel.Run
  let running: Bool
  @State private var glow = false
  @State private var spin = false

  var body: some View {
    ZStack {
      // Soft pulse around the inner disc.
      Circle()
        .fill(Color.sectorAccent.opacity(0.08))
        .padding(glow ? 12 : 26)
        .opacity(running ? 1 : 0)
      Circle()
        .fill(Color.sectorCard)
        .overlay(Circle().strokeBorder(Color.sectorHairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 25, y: 20)
        .padding(26)

      Circle()
        .inset(by: 14)
        .stroke(Color.sectorTrack, lineWidth: 16)
      Circle()
        .inset(by: 14)
        .trim(from: 0, to: max(0.001, run.fraction))
        .stroke(
          LinearGradient.sectorClean(.topLeading, .bottomTrailing),
          style: StrokeStyle(lineWidth: 16, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
        .animation(.linear(duration: 0.25), value: run.fraction)

      if running {
        Circle()
          .fill(.white)
          .overlay(Circle().strokeBorder(Color.sectorAccent, lineWidth: 2))
          .frame(width: 10, height: 10)
          .offset(y: -126)
          .rotationEffect(.degrees(spin ? 360 : 0))
          .onAppear {
            guard !Motion.reduced else { return }
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) { spin = true }
          }
          .onDisappear { spin = false }
          .transition(.opacity)
      }

      center
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
    .overlay {
      if running && !Motion.reduced { FlyingFiles().allowsHitTesting(false) }
    }
    .animation(Motion.resolve(Motion.quick), value: running)
    .onAppear {
      guard !Motion.reduced else { return }
      withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { glow = true }
    }
  }

  @ViewBuilder private var center: some View {
    if let result = run.result {
      VStack(spacing: 10) {
        Image(systemName: "checkmark")
          .font(.system(size: 30, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 64, height: 64)
          .background(Color(hex: 0x34C759), in: .circle)
          .shadow(color: Color(hex: 0x34C759).opacity(0.4), radius: 12, y: 10)
        Text("\(ByteFormat.string(result.freedBytes)) свободно")
          .font(.system(size: 15, weight: .bold))
          .monospacedDigit()
      }
      .transition(.scale(scale: 0.2).combined(with: .opacity).animation(Motion.resolve(Motion.bouncy)))
    } else {
      let parts = ByteFormat.parts(run.progress.freedBytes)
      VStack(spacing: 0) {
        Text("Освобождено").font(.system(size: 12)).foregroundStyle(.secondary)
        Text(parts.number)
          .font(.system(size: 44, weight: .bold))
          .tracking(-1.2)
          .monospacedDigit()
          .contentTransition(.numericText(value: Double(run.progress.freedBytes)))
          .frame(height: 50)
        Text("\(parts.unit) из \(ByteFormat.string(run.plannedBytes))")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      .transition(.opacity)
    }
  }
}

/// Little file tiles flying from the list into the ring (mock `fly1…3`).
private struct FlyingFiles: View {
  private struct Tile {
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    var color: Color
    var path: Int
    var duration: Double
    var delay: Double
  }

  /// Start y, middle point and rotations of the three CSS paths.
  private static let paths: [(startY: Double, mid: CGPoint, rotation: (Double, Double))] = [
    (-110, CGPoint(x: 220, y: -150), (120, 260)),
    (20, CGPoint(x: 230, y: -30), (-110, -240)),
    (160, CGPoint(x: 220, y: 150), (90, 220)),
  ]

  private static let tiles: [Tile] = [
    Tile(width: 12, height: 14, radius: 3, color: Color(hex: 0x5E5CE6), path: 0, duration: 1.6, delay: 0),
    Tile(width: 10, height: 12, radius: 3, color: Color(hex: 0x34C759), path: 1, duration: 1.8, delay: 0.3),
    Tile(width: 12, height: 14, radius: 3, color: Color(hex: 0x0071E3), path: 2, duration: 1.7, delay: 0.6),
    Tile(width: 8, height: 10, radius: 2, color: Color(hex: 0x30B0C7), path: 0, duration: 2.0, delay: 0.9),
    Tile(width: 10, height: 12, radius: 3, color: Color(hex: 0xFF9500), path: 1, duration: 1.5, delay: 1.1),
    Tile(width: 8, height: 10, radius: 2, color: Color(hex: 0xAF52DE), path: 2, duration: 1.9, delay: 1.3),
  ]

  private static let curve = UnitCurve.bezier(
    startControlPoint: UnitPoint(x: 0.45, y: 0.05), endControlPoint: UnitPoint(x: 0.55, y: 0.95))

  @State private var start = Date()

  var body: some View {
    TimelineView(.animation) { context in
      let elapsed = context.date.timeIntervalSince(start)
      ZStack {
        ForEach(Self.tiles.indices, id: \.self) { i in
          let tile = Self.tiles[i]
          let t = elapsed - tile.delay
          if t >= 0 {
            let p = t.truncatingRemainder(dividingBy: tile.duration) / tile.duration
            let path = Self.paths[tile.path]
            let x = Keyframes(stops: [(0, 470), (0.55, path.mid.x), (1, 0)], curve: Self.curve)
            let y = Keyframes(stops: [(0, path.startY), (0.55, path.mid.y), (1, 0)], curve: Self.curve)
            let scale = Keyframes(stops: [(0, 1), (0.55, 0.85), (1, 0.2)], curve: Self.curve)
            let angle = Keyframes(
              stops: [(0, 0), (0.55, path.rotation.0), (1, path.rotation.1)], curve: Self.curve)
            let opacity = Keyframes(stops: [(0, 0), (0.1, 1), (1, 0)], curve: Self.curve)
            RoundedRectangle(cornerRadius: tile.radius)
              .fill(tile.color)
              .frame(width: tile.width, height: tile.height)
              .scaleEffect(scale.value(at: p))
              .rotationEffect(.degrees(angle.value(at: p)))
              .offset(x: x.value(at: p), y: y.value(at: p))
              .opacity(opacity.value(at: p))
          }
        }
      }
    }
    .accessibilityHidden(true)
  }
}

/// Thin bar under the ring with a moving sheen while running.
private struct ProgressStrip: View {
  var fraction: Double
  var running: Bool

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(Color.sectorTrack)
        Capsule()
          .fill(LinearGradient.sectorClean())
          .frame(width: max(6, width * fraction))
          .animation(.linear(duration: 0.25), value: fraction)
        if running && !Motion.reduced {
          LinearGradient(
            colors: [.white.opacity(0), .white.opacity(0.7), .white.opacity(0)],
            startPoint: .leading, endPoint: .trailing
          )
          .frame(width: 60)
          .keyframeAnimator(initialValue: -60.0, repeating: true) { sheen, x in
            sheen.offset(x: x)
          } keyframes: { _ in
            LinearKeyframe(width + 60, duration: 1.2)
          }
        }
      }
    }
    .clipShape(.capsule)
  }
}

// MARK: - Steps

private struct StepList: View {
  let run: SmartCleanModel.Run

  var body: some View {
    VStack(spacing: 6) {
      ForEach(Array(run.steps.enumerated()), id: \.element.id) { index, step in
        StepRow(
          step: step, progress: run.progress.steps[index], isPaused: run.isPaused,
          wasStopped: run.result?.wasCancelled == true
        )
        .appearAnimation(delay: Double(index) * 0.06, offset: 12)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Этапы очистки")
  }
}

private struct StepRow: View {
  let step: CleanupStep
  let progress: CleanupProgress.Step
  let isPaused: Bool
  let wasStopped: Bool

  var body: some View {
    let state = progress.state
    let color: Color =
      switch state {
      case .done: .sectorSuccess
      case .active: .primary
      case .pending: .secondary
      }
    HStack(spacing: 12) {
      ZStack {
        switch state {
        case .done:
          Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Color(hex: 0x34C759), in: .circle)
            .transition(.scale(scale: 0.1).animation(Motion.resolve(Motion.bouncy)))
        case .active:
          Spinner(paused: isPaused || wasStopped).transition(.opacity)
        case .pending:
          Circle()
            .strokeBorder(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
            .frame(width: 18, height: 18)
            .transition(.opacity)
        }
      }
      .frame(width: 26, height: 26)

      VStack(alignment: .leading, spacing: 1) {
        Text(step.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
        Text(detail)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .contentTransition(.numericText())
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(ByteFormat.string(state == .pending ? step.plannedBytes : progress.freedBytes))
        .font(.system(size: 13, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(color)
        .contentTransition(.numericText())
    }
    .padding(.leading, 12)
    .padding(.trailing, 16)
    .frame(height: 58)
    .background(background, in: .rect(cornerRadius: 16))
    .overlay {
      if state == .active {
        RoundedRectangle(cornerRadius: 16).strokeBorder(Color.sectorAccent.opacity(0.25), lineWidth: 0.5)
      }
    }
    .animation(Motion.resolve(Motion.quick), value: state)
  }

  private var background: Color {
    switch progress.state {
    case .active: Color.sectorAccent.opacity(0.09)
    case .done: Color.sectorCard.opacity(0.8)
    case .pending: Color.sectorCard.opacity(0.5)
    }
  }

  private var detail: String {
    let planned = step.plannedObjects
    switch progress.state {
    case .done:
      var text = String(
        localized: "Готово · \(Plural.format(progress.objectsDone, "объект", "объекта", "объектов"))")
      if progress.failures > 0 {
        text += " · " + String(localized: "пропущено \(progress.failures)")
      }
      return text
    case .active:
      if wasStopped { return String(localized: "Остановлено") }
      if isPaused { return String(localized: "Пауза") }
      let done = min(progress.objectsDone, planned).formatted()
      return String(localized: "Удаляем… \(done) из \(planned.formatted())")
    case .pending:
      return wasStopped ? String(localized: "Пропущено") : String(localized: "В очереди")
    }
  }
}

/// Small rotating arc for the active step.
private struct Spinner: View {
  var paused: Bool
  @State private var turning = false

  var body: some View {
    ZStack {
      Circle().stroke(Color.sectorAccent.opacity(0.2), lineWidth: 2.5)
      Circle()
        .trim(from: 0, to: 0.25)
        .stroke(Color.sectorAccent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        .rotationEffect(.degrees(turning ? 360 : 0))
    }
    .frame(width: 18, height: 18)
    .onAppear { spin(!paused) }
    .onChange(of: paused) { _, paused in spin(!paused) }
  }

  private func spin(_ on: Bool) {
    if on && !Motion.reduced {
      turning = false
      withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { turning = true }
    } else {
      withAnimation(.linear(duration: 0.1)) { turning = false }
    }
  }
}
