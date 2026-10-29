import SectorCore
import SwiftUI

/// Disk usage: category donut with free space in the middle, used-space
/// bar and a legend; hovering any of them highlights the same category.
struct UsageCard: View {
  @Environment(AppModel.self) private var model
  @State private var hovered: DiskCategory?

  private struct Slice: Identifiable, Equatable {
    var id: DiskCategory { category }
    var category: DiskCategory
    var size: UInt64
    var start: Double
    var end: Double
  }

  var body: some View {
    let volume = model.volume
    let ordered = model.breakdown?.ordered ?? []
    let sum = ordered.reduce(0) { $0 + $1.size }
    let capacity = max(volume?.total ?? 0, sum, 1)
    let slices = makeSlices(ordered, capacity: capacity)

    HStack(spacing: 30) {
      UsageDonut(
        slices: slices.map { .init(category: $0.category, start: $0.start, end: $0.end) },
        sizes: Dictionary(uniqueKeysWithValues: slices.map { ($0.category, $0.size) }),
        free: volume?.available ?? 0, hovered: $hovered
      )
      .frame(width: 190, height: 190)

      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 8) {
          Text(volume?.name ?? "Macintosh HD")
            .font(.system(size: 13, weight: .semibold))
          Text(driveLabel(volume))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8))
        }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          CountingByteText(bytes: volume?.used ?? sum)
            .font(.system(size: 36, weight: .bold))
            .tracking(-0.8)
          Text("из \(HeroBytes.string(volume?.total ?? capacity)) занято")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
        }
        .padding(.top, 6)

        UsageBar(slices: slices.map { ($0.category, $0.end - $0.start) }, hovered: hovered)
          .frame(height: 14)
          .padding(.top, 12)

        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
          alignment: .leading, spacing: 4
        ) {
          ForEach(slices) { slice in
            LegendChip(
              category: slice.category, size: slice.size, isHovered: hovered == slice.category
            ) { inside in
              if inside {
                hovered = slice.category
              } else if hovered == slice.category {
                hovered = nil
              }
            }
          }
        }
        .padding(.top, 12)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.leading, 22)
    .padding(.trailing, 28)
    .frame(minHeight: 214)
    .overviewCard()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Использование диска")
  }

  private func makeSlices(
    _ ordered: [(category: DiskCategory, size: UInt64)], capacity: UInt64
  ) -> [Slice] {
    var cursor = 0.0
    return ordered.map { item in
      let span = Double(item.size) / Double(capacity)
      defer { cursor += span }
      return Slice(category: item.category, size: item.size, start: cursor, end: cursor + span)
    }
  }

  private func driveLabel(_ volume: VolumeInfo?) -> String {
    guard let volume else { return "SSD" }
    let kind = volume.isInternal ? "SSD" : String(localized: "Внешний")
    return volume.fileSystem.isEmpty ? kind : "\(volume.fileSystem) · \(kind)"
  }
}

/// The category ring. Segments grow in one after another; the hovered one
/// pops out and the others dim.
private struct UsageDonut: View {
  struct Arc: Equatable {
    var category: DiskCategory
    var start: Double
    var end: Double
  }

  var slices: [Arc]
  var sizes: [DiskCategory: UInt64]
  var free: UInt64
  @Binding var hovered: DiskCategory?
  @State private var appeared = false

  private let innerRatio = 62.0 / 95.0

  var body: some View {
    ZStack {
      Circle()
        .strokeBorder(Color.sectorTrack, lineWidth: 190 * (1 - innerRatio) / 2 - 1)
        .padding(1)
      ForEach(Array(slices.enumerated()), id: \.element.category) { index, arc in
        let isHovered = hovered == arc.category
        let isDimmed = hovered != nil && !isHovered
        DonutArc(start: arc.start, end: arc.end, innerRatio: innerRatio)
          .fill(arc.category.color)
          .scaleEffect(isHovered ? 1.06 : 1)
          .opacity(isDimmed ? 0.28 : 1)
          .animation(Motion.resolve(Motion.bouncy), value: hovered)
          .rotationEffect(.degrees(appeared ? 0 : -30))
          .scaleEffect(appeared ? 1 : 0.8)
          .opacity(appeared ? 1 : 0)
          .animation(
            Motion.resolve(.spring(duration: 1, bounce: 0.3))
              .delay(Motion.reduced ? 0 : 0.15 + Double(index) * 0.08),
            value: appeared)
      }
      center
    }
    .contentShape(Circle())
    .onContinuousHover { phase in
      switch phase {
      case .active(let point): updateHover(point)
      case .ended: hovered = nil
      }
    }
    .onAppear { appeared = true }
  }

  private var center: some View {
    let value = hovered.flatMap { sizes[$0] } ?? free
    let unit = ByteFormat.localizedUnit(HeroBytes.unitIndex(value))
    return VStack(spacing: 0) {
      CountingByteText(bytes: value, showsUnit: false, changeAnimation: nil)
        .font(.system(size: 24, weight: .bold))
        .tracking(-0.5)
        .contentTransition(.numericText())
      Text(hovered.map { "\($0.title), \(unit)" } ?? String(localized: "\(unit) свободно"))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .frame(maxWidth: 96)
    }
    .animation(Motion.resolve(Motion.quick), value: hovered)
    .allowsHitTesting(false)
  }

  private func updateHover(_ point: CGPoint) {
    let radius = 95.0
    let dx = Double(point.x) - radius
    let dy = Double(point.y) - radius
    let r = (dx * dx + dy * dy).squareRoot()
    guard r >= radius * innerRatio - 2, r <= radius + 4 else {
      if hovered != nil { hovered = nil }
      return
    }
    let fraction = SunburstRings.fraction(dx: dx, dy: dy)
    let hit = slices.first { fraction >= $0.start && fraction < $0.end }?.category
    if hit != hovered { hovered = hit }
  }
}

/// Ring segment between angle fractions (clockwise from twelve o'clock).
private struct DonutArc: Shape {
  var start: Double
  var end: Double
  var innerRatio: Double

  var animatableData: AnimatablePair<Double, Double> {
    get { AnimatablePair(start, end) }
    set {
      start = newValue.first
      end = newValue.second
    }
  }

  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let r1 = min(rect.width, rect.height) / 2
    let r0 = r1 * innerRatio
    var a0 = start
    var a1 = min(end, start + 0.99999)
    // 1 pt gaps between neighbours, like the mock's white stroke.
    let pad = 1 / (2 * .pi * r1)
    if (a1 - a0) > pad * 3 {
      a0 += pad
      a1 -= pad
    }
    let s = Angle.radians(a0 * 2 * .pi - .pi / 2)
    let e = Angle.radians(a1 * 2 * .pi - .pi / 2)
    var path = Path()
    path.addArc(center: center, radius: r1, startAngle: s, endAngle: e, clockwise: false)
    path.addArc(center: center, radius: r0, startAngle: e, endAngle: s, clockwise: true)
    path.closeSubpath()
    return path
  }
}

/// Stacked used-space bar; segments grow from the left one after another.
private struct UsageBar: View {
  var slices: [(category: DiskCategory, fraction: Double)]
  var hovered: DiskCategory?
  @State private var appeared = false

  var body: some View {
    GeometryReader { geo in
      HStack(spacing: 2) {
        ForEach(Array(slices.enumerated()), id: \.element.category) { index, slice in
          Rectangle()
            .fill(slice.category.color)
            .frame(width: max(2, geo.size.width * slice.fraction - 2))
            .opacity(hovered == nil || hovered == slice.category ? 1 : 0.3)
            .animation(Motion.resolve(Motion.quick), value: hovered)
            .scaleEffect(x: appeared ? 1 : 0, anchor: .leading)
            .animation(
              Motion.resolve(.spring(duration: 0.9, bounce: 0))
                .delay(Motion.reduced ? 0 : 0.3 + Double(index) * 0.09),
              value: appeared)
        }
        Spacer(minLength: 0)
      }
    }
    .background(Color.primary.opacity(0.06))
    .clipShape(.rect(cornerRadius: 7))
    .onAppear { appeared = true }
    .accessibilityHidden(true)
  }
}

/// Legend entry; hovering it highlights the category everywhere.
private struct LegendChip: View {
  var category: DiskCategory
  var size: UInt64
  var isHovered: Bool
  var onHover: (Bool) -> Void

  var body: some View {
    HStack(spacing: 7) {
      RoundedRectangle(cornerRadius: 3)
        .fill(category.color)
        .frame(width: 9, height: 9)
      Text(category.title)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(ByteFormat.string(size))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
    .font(.system(size: 12))
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.primary.opacity(isHovered ? 0.07 : 0), in: .rect(cornerRadius: 9))
    .contentShape(.rect(cornerRadius: 9))
    .onHover(perform: onHover)
    .animation(Motion.resolve(Motion.quick), value: isHovered)
    .accessibilityElement(children: .combine)
  }
}
