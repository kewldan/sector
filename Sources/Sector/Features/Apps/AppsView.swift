import AppKit
import SectorCore
import SwiftUI

/// "Приложения" (design/mockups/Apps.dc.html): a grid of installed apps
/// sorted by size or by how long they went unused, and a panel that removes
/// the selected app together with its data.
struct AppsView: View {
  @Environment(AppModel.self) private var model

  private var apps: AppsModel { model.apps }

  var body: some View {
    @Bindable var apps = apps
    content
      .navigationTitle("Приложения")
      .navigationSubtitle(subtitle)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Picker("Сортировка", selection: $apps.sort.animation(Motion.resolve(Motion.smooth))) {
            Text("По размеру").tag(AppsModel.Sort.size)
            Text("Давно не открывал").tag(AppsModel.Sort.age)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(width: 240)
        }
      }
      .task(id: apps.generation) { apps.startIfNeeded() }
      .task {
        let center = NSWorkspace.shared.notificationCenter
        for await _ in center.notifications(named: NSWorkspace.didTerminateApplicationNotification)
          .map({ _ in () })
        {
          apps.refreshRunning()
        }
      }
      .task {
        let center = NSWorkspace.shared.notificationCenter
        for await _ in center.notifications(named: NSWorkspace.didLaunchApplicationNotification)
          .map({ _ in () })
        {
          apps.refreshRunning()
        }
      }
  }

  @ViewBuilder private var content: some View {
    switch apps.state {
    case .idle, .loading:
      VStack(spacing: 12) {
        ProgressView().controlSize(.large)
        Text("Ищем приложения…").font(.sectorBody).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .transition(.opacity)
    case .ready:
      if apps.apps.isEmpty {
        EmptyStateView(
          symbol: "square.grid.2x2", title: "Приложений не найдено",
          message: "В папке «Программы» нет приложений, которые можно удалить.")
      } else {
        HStack(alignment: .top, spacing: 14) {
          AppGrid()
          if let selected = apps.selected {
            AppDetail(item: selected)
              .frame(width: 300)
              .appearAnimation(delay: 0.2)
          }
        }
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .padding(.top, 4)
        .padding(.bottom, 16)
      }
    }
  }

  private var subtitle: String {
    guard apps.state == .ready else { return "" }
    let count = Plural.format(apps.apps.count, "приложение", "приложения", "приложений")
    return String(localized: "\(count) · \(ByteFormat.string(apps.totalSize)) вместе с данными")
  }
}

// MARK: - Grid

private struct AppGrid: View {
  @Environment(AppModel.self) private var model
  private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

  var body: some View {
    let apps = model.apps
    ScrollView {
      LazyVGrid(columns: columns, spacing: 10) {
        ForEach(Array(apps.sorted.enumerated()), id: \.element.id) { index, item in
          AppCard(item: item, index: index, isSelected: item.id == apps.selected?.id) {
            withAnimation(Motion.resolve(Motion.quick)) { apps.selectedID = item.id }
          }
        }
      }
      .padding(14)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.sectorCard.opacity(0.75), in: .rect(cornerRadius: Metrics.cardRadius))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.cardRadius)
        .strokeBorder(Color.sectorHairline, lineWidth: 0.5)
    )
    .clipShape(.rect(cornerRadius: Metrics.cardRadius))
  }
}

private struct AppCard: View {
  var item: InstalledApp
  var index: Int
  var isSelected: Bool
  var action: () -> Void

  @Environment(AppModel.self) private var model
  @State private var appeared = false
  @State private var hovering = false
  @State private var jiggle = 0

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        AppIconView(url: item.url, size: 40)
          .keyframeAnimator(initialValue: 0.0, trigger: jiggle) { icon, angle in
            icon.rotationEffect(.degrees(angle))
          } keyframes: { _ in
            KeyframeTrack {
              CubicKeyframe(-3.5, duration: 0.09)
              CubicKeyframe(3.5, duration: 0.17)
              CubicKeyframe(-3.5, duration: 0.18)
              CubicKeyframe(3.5, duration: 0.17)
              CubicKeyframe(0, duration: 0.09)
            }
          }
        VStack(alignment: .leading, spacing: 1) {
          Text(item.name)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
          Text(AppAge.text(item.lastUsed))
            .font(.system(size: 11))
            .foregroundStyle(AppAge.color(item.lastUsed))
            .lineLimit(1)
        }
        Spacer(minLength: 4)
        SizeText(bytes: item.totalSize, font: .system(size: 12, weight: .semibold))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background {
        RoundedRectangle(cornerRadius: 16)
          .fill(Color.sectorCard.opacity(isSelected ? 1 : 0.6))
      }
      .overlay {
        RoundedRectangle(cornerRadius: 16)
          .strokeBorder(
            isSelected ? Color.sectorAccent : Color.primary.opacity(0.07),
            lineWidth: isSelected ? 2 : 0.5)
      }
      .shadow(
        color: isSelected ? Color.sectorAccent.opacity(0.18) : .clear, radius: 12, y: 5
      )
      .contentShape(.rect(cornerRadius: 16))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .contextMenu {
      Button("Показать в Finder") { model.revealInFinder([item.url]) }
    }
    .offset(y: hovering && !Motion.reduced ? -3 : 0)
    .onHover { hover in
      withAnimation(Motion.resolve(.spring(duration: 0.35, bounce: 0.4))) { hovering = hover }
      if hover && !Motion.reduced { jiggle += 1 }
    }
    .animation(Motion.resolve(Motion.quick), value: isSelected)
    .opacity(appeared ? 1 : 0)
    .scaleEffect(appeared || Motion.reduced ? 1 : 0.85)
    .offset(y: appeared || Motion.reduced ? 0 : 10)
    .onAppear {
      guard !appeared else { return }
      withAnimation(
        Motion.resolve(.spring(duration: 0.55, bounce: 0.3)).delay(
          Motion.reduced ? 0 : Motion.stagger(index, step: 0.04))
      ) { appeared = true }
    }
  }
}

// MARK: - Detail

private struct AppDetail: View {
  @Environment(AppModel.self) private var model
  var item: InstalledApp

  private var apps: AppsModel { model.apps }

  var body: some View {
    let running = apps.isRunning(item)
    let checked = apps.checkedRelated(item)
    VStack(alignment: .leading, spacing: 0) {
      header
        .id(item.id)

      if running {
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(Color.sectorWarningFill)
          VStack(alignment: .leading, spacing: 6) {
            Text("Приложение запущено. Завершите его, чтобы удалить.")
              .font(.system(size: 12))
              .fixedSize(horizontal: false, vertical: true)
            Button("Завершить") { apps.quit(item) }
              .buttonStyle(.glass)
              .controlSize(.small)
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sectorWarningFill.opacity(0.12), in: .rect(cornerRadius: 12))
        .padding(.top, 14)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
      }

      Text("Будет удалено вместе с приложением")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.top, 18)
        .padding(.bottom, 6)

      ScrollView {
        PartsTree(item: item)
          .id(item.id)
      }
      .scrollIndicators(.never)

      Spacer(minLength: 0)

      Divider().opacity(0.6)
      HStack(alignment: .firstTextBaseline) {
        Text("Освободится")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
        Spacer()
        SizeText(bytes: apps.removalSize(item), font: .system(size: 22, weight: .bold))
          .tracking(-0.4)
      }
      .padding(.horizontal, 2)
      .padding(.top, 12)
      .padding(.bottom, 10)

      HStack(spacing: 8) {
        Button {
          apps.resetData(item)
        } label: {
          Text("Сбросить данные").frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .disabled(running || checked.isEmpty)
        .layoutPriority(1)

        Button {
          apps.removeCompletely(item)
        } label: {
          Text("Удалить полностью").frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(Color.sectorDanger)
        .disabled(running)
        .layoutPriority(1.3)
      }
      .font(.system(size: 12, weight: .semibold))
      .controlSize(.large)
    }
    .padding(.horizontal, 18)
    .padding(.top, 20)
    .padding(.bottom, 16)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Color.sectorCard, in: .rect(cornerRadius: Metrics.cardRadius))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.cardRadius)
        .strokeBorder(Color.sectorHairline, lineWidth: 0.5)
    )
    .shadow(color: Color(hex: 0x141E46).opacity(0.05), radius: 3, y: 1)
    .animation(Motion.resolve(Motion.smooth), value: running)
  }

  private var header: some View {
    VStack(spacing: 0) {
      BigAppIcon(url: item.url, stale: AppAge.isStale(item.lastUsed))
      Text(item.name)
        .font(.system(size: 17, weight: .bold))
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .padding(.top, 12)
      if let version = versionLine {
        Text(version)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .padding(.top, 2)
      }
      if AppAge.isStale(item.lastUsed) {
        StaleBadge(text: AppAge.text(item.lastUsed))
          .padding(.top, 8)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var versionLine: String? {
    switch (item.version, item.vendor) {
    case let (version?, vendor?): return String(localized: "Версия \(version) · \(vendor)")
    case let (version?, nil): return String(localized: "Версия \(version)")
    case let (nil, vendor?): return vendor
    case (nil, nil): return nil
    }
  }
}

/// The 76 pt icon that drops in and, for long-unused apps, jiggles.
private struct BigAppIcon: View {
  var url: URL
  var stale: Bool

  @State private var dropped = false
  @State private var jiggle = 0

  var body: some View {
    AppIconView(url: url, size: 76)
      .shadow(color: .black.opacity(0.22), radius: 13, y: 12)
      .keyframeAnimator(initialValue: 0.0, trigger: jiggle) { icon, angle in
        icon.rotationEffect(.degrees(angle))
      } keyframes: { _ in
        KeyframeTrack {
          CubicKeyframe(-3.5, duration: 0.11)
          CubicKeyframe(3.5, duration: 0.22)
          CubicKeyframe(-3.5, duration: 0.23)
          CubicKeyframe(3.5, duration: 0.22)
          CubicKeyframe(-3.5, duration: 0.23)
          CubicKeyframe(3.5, duration: 0.22)
          CubicKeyframe(0, duration: 0.12)
        }
      }
      .opacity(dropped ? 1 : 0)
      .scaleEffect(dropped || Motion.reduced ? 1 : 0.7)
      .offset(y: dropped || Motion.reduced ? 0 : -24)
      .onAppear {
        withAnimation(Motion.resolve(.spring(duration: 0.7, bounce: 0.35))) { dropped = true }
      }
      .task {
        guard stale, !Motion.reduced else { return }
        try? await Task.sleep(for: .milliseconds(900))
        jiggle += 1
      }
  }
}

private struct StaleBadge: View {
  var text: String
  @State private var pulse = false

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(Color.sectorWarningFill)
        .frame(width: 6, height: 6)
        .opacity(pulse ? 0.55 : 1)
      Text(text)
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(Color.sectorWarning)
    .padding(.horizontal, 10)
    .padding(.vertical, 3)
    .background(Color.sectorWarningFill.opacity(0.14), in: .capsule)
    .onAppear {
      guard !Motion.reduced else { return }
      withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
    }
  }
}

/// The app bundle and its related data as branches of a tree line.
private struct PartsTree: View {
  @Environment(AppModel.self) private var model
  var item: InstalledApp

  @State private var grown = false

  var body: some View {
    let apps = model.apps
    VStack(alignment: .leading, spacing: 2) {
      PartRow(
        index: 0, title: item.url.lastPathComponent,
        path: (item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
        size: item.size, isOn: .constant(true), locked: true)
      ForEach(Array(item.related.enumerated()), id: \.element.id) { index, related in
        PartRow(
          index: index + 1, title: related.kind.folder,
          path: (related.url.path as NSString).abbreviatingWithTildeInPath, size: related.size,
          isOn: Binding(
            get: { apps.isChecked(related) },
            set: { on in
              withAnimation(Motion.resolve(Motion.quick)) { apps.setChecked(related, on) }
            }),
          locked: false)
      }
      if item.related.isEmpty {
        Text("Других данных не найдено")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
      }
    }
    .padding(.leading, 14)
    .background(alignment: .topLeading) {
      Capsule()
        .fill(Color.primary.opacity(0.14))
        .frame(width: 1.5)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .padding(.leading, 4)
        .scaleEffect(x: 1, y: grown ? 1 : 0, anchor: .top)
    }
    .onAppear {
      withAnimation(Motion.resolve(Motion.smooth).delay(Motion.reduced ? 0 : 0.3)) {
        grown = true
      }
    }
  }
}

private struct PartRow: View {
  var index: Int
  var title: String
  var path: String
  var size: UInt64
  @Binding var isOn: Bool
  var locked: Bool

  @State private var appeared = false

  var body: some View {
    HStack(spacing: 8) {
      Toggle(isOn: $isOn) { EmptyView() }
        .toggleStyle(.checkbox)
        .labelsHidden()
        .controlSize(.small)
        .disabled(locked)
      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .font(.system(size: 12, weight: .medium))
          .lineLimit(1)
        Text(path)
          .font(.system(size: 10.5))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 4)
      SizeText(bytes: size, font: .system(size: 12, weight: .semibold))
        .opacity(isOn ? 1 : 0.4)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(Color.primary.opacity(0.03), in: .rect(cornerRadius: 10))
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(Color.primary.opacity(0.14))
        .frame(width: 9, height: 1.5)
        .offset(x: -10)
    }
    .help(path)
    .opacity(appeared ? 1 : 0)
    .offset(x: appeared || Motion.reduced ? 0 : -10)
    .onAppear {
      withAnimation(
        Motion.resolve(Motion.smooth).delay(
          Motion.reduced ? 0 : 0.35 + Double(min(index, 12)) * 0.09)
      ) { appeared = true }
    }
  }
}
