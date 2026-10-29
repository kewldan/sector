import SectorCore
import SwiftUI

/// "Дубликаты" (design/mockups/Duplicates.dc.html): groups of identical
/// files on the left, the selected group's copies on the right. Clicking a
/// copy keeps it; the rest are marked for deletion.
struct DuplicatesView: View {
  @Environment(AppModel.self) private var model

  private var dup: DuplicatesModel { model.duplicates }

  var body: some View {
    content
      .navigationTitle("Дубликаты")
      .navigationSubtitle(subtitle)
      .toolbar {
        if dup.state == .ready, !dup.groups.isEmpty {
          ToolbarItem(placement: .primaryAction) {
            Button {
              withAnimation(Motion.resolve(Motion.bouncy)) { dup.autoSelect() }
            } label: {
              Label {
                Text("Автовыбор оригиналов")
              } icon: {
                Image(systemName: "sparkle")
                  .foregroundStyle(Color(hex: 0x5E5CE6))
                  .symbolEffect(.breathe, options: .repeat(.continuous), isActive: !Motion.reduced)
              }
              .labelStyle(.titleAndIcon)
            }
          }
        }
      }
      .task(id: dup.generation) { dup.startIfNeeded() }
  }

  @ViewBuilder private var content: some View {
    switch dup.state {
    case .idle, .finding:
      DuplicatesProgressView()
        .transition(.opacity)
    case .cancelled:
      EmptyStateView(
        symbol: "stop.circle", title: "Поиск остановлен",
        message: "Проверка содержимого прервана. Её можно запустить заново."
      ) {
        Button("Начать заново") { dup.start() }
          .buttonStyle(.glass)
      }
    case .ready:
      if dup.groups.isEmpty {
        NoDuplicatesView()
      } else {
        HStack(alignment: .top, spacing: 14) {
          DuplicateGroupList()
            .frame(width: 320)
          if let group = dup.selectedGroup {
            DuplicateDetail(group: group)
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
    switch dup.state {
    case .ready where !dup.groups.isEmpty:
      let groups = Plural.format(dup.groups.count, "группа", "группы", "групп")
      return String(localized: "\(groups) · \(ByteFormat.string(dup.totalWaste)) лишних копий")
    case .idle, .finding:
      return String(localized: "Сравниваем содержимое файлов")
    default:
      return ""
    }
  }
}

// MARK: - Group list

private struct DuplicateGroupList: View {
  @Environment(AppModel.self) private var model
  private var dup: DuplicatesModel { model.duplicates }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(Array(dup.visibleGroups.enumerated()), id: \.element.id) { index, group in
            DuplicateGroupRow(
              group: group, index: index, isSelected: group.id == dup.selectedGroup?.id
            ) {
              withAnimation(Motion.resolve(Motion.quick)) { dup.selectedID = group.id }
            }
          }
        }
        .padding(8)
      }
      .scrollIndicators(.automatic)
      HStack(spacing: 6) {
        Text(caption)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .monospacedDigit()
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 18)
      .padding(.top, 6)
      .padding(.bottom, 12)
    }
    .frame(maxHeight: .infinity)
    .background(Color.sectorCard, in: .rect(cornerRadius: Metrics.cardRadius))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.cardRadius)
        .strokeBorder(Color.sectorHairline, lineWidth: 0.5)
    )
    .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
  }

  private var caption: String {
    let shown = dup.visibleGroups.count
    let total = Plural.format(dup.groups.count, "группы", "групп", "групп")
    return String(localized: "Показано \(shown) из \(total) · сортировка по размеру")
  }
}

private struct DuplicateGroupRow: View {
  @Environment(AppModel.self) private var model
  var group: DuplicateGroup
  var index: Int
  var isSelected: Bool
  var action: () -> Void

  @State private var hovering = false
  @State private var appeared = false

  var body: some View {
    let waste = model.duplicates.waste(group)
    Button(action: action) {
      HStack(spacing: 10) {
        ThumbnailFan(group: group, spread: hovering)
          .frame(width: 52, height: 44)
        VStack(alignment: .leading, spacing: 1) {
          Text(group.name)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
          Text(meta)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        Spacer(minLength: 4)
        SizeText(bytes: waste, font: .system(size: 12, weight: .semibold))
          .foregroundStyle(waste >= 1_000_000_000 ? Color.sectorWarning : Color.primary.opacity(0.8))
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background {
        RoundedRectangle(cornerRadius: Metrics.rowRadius)
          .fill(isSelected ? Color.sectorAccent.opacity(0.11) : hovering ? Color.primary.opacity(0.035) : .clear)
          .overlay(
            RoundedRectangle(cornerRadius: Metrics.rowRadius)
              .strokeBorder(isSelected ? Color.sectorAccent.opacity(0.25) : .clear, lineWidth: 0.5))
      }
      .contentShape(.rect(cornerRadius: Metrics.rowRadius))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .onHover { hover in
      withAnimation(Motion.resolve(Motion.quick)) { hovering = hover }
    }
    .opacity(appeared ? 1 : 0)
    .offset(x: appeared || Motion.reduced ? 0 : -14)
    .onAppear {
      guard !appeared else { return }
      withAnimation(Motion.resolve(Motion.smooth).delay(Motion.stagger(index, step: 0.055))) {
        appeared = true
      }
    }
    .contextMenu {
      Button("Показать в Finder") { model.revealInFinder(group.files.map(\.url)) }
    }
  }

  private var meta: String {
    let copies = Plural.format(group.files.count, "копия", "копии", "копий")
    return String(localized: "\(copies) · по \(ByteFormat.string(group.size))")
  }
}

/// Three stacked tiles of the group's thumbnail that fan out on hover.
private struct ThumbnailFan: View {
  var group: DuplicateGroup
  var spread: Bool

  var body: some View {
    let path = group.files.first?.path ?? ""
    let kind = DuplicateKind(path: path)
    ZStack {
      tile(path, kind).rotationEffect(.degrees(spread ? -16 : -8)).offset(x: spread ? -7 : -4, y: spread ? 1 : 0)
      tile(path, kind).rotationEffect(.degrees(spread ? 14 : 7)).offset(x: spread ? 7 : 4, y: spread ? 1 : 0)
      tile(path, kind).offset(y: spread ? -3 : 0)
    }
    .animation(Motion.resolve(Motion.bouncy), value: spread)
    .accessibilityHidden(true)
  }

  private func tile(_ path: String, _ kind: DuplicateKind) -> some View {
    RoundedRectangle(cornerRadius: 7)
      .fill(kind.background)
      .overlay {
        FileThumbnail(path: path, side: 72)
          .clipShape(.rect(cornerRadius: 7))
      }
      .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
      .frame(width: 32, height: 36)
      .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
  }
}

// MARK: - Detail

private struct DuplicateDetail: View {
  @Environment(AppModel.self) private var model
  var group: DuplicateGroup

  private var dup: DuplicatesModel { model.duplicates }
  private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)

  var body: some View {
    let keep = dup.keptPath(group)
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .bottom, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(group.name)
            .font(.system(size: 20, weight: .bold))
            .tracking(-0.4)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(detail)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        Spacer(minLength: 12)
        Text("Содержимое идентично · SHA-256")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.sectorSuccess)
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .background(Color(hex: 0x34C759).opacity(0.14), in: .rect(cornerRadius: 10))
          .fixedSize()
          .help(group.id)
      }
      Text("Нажмите на копию, чтобы оставить её. Остальные будут удалены.")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.top, 14)

      ScrollView {
        LazyVGrid(columns: columns, spacing: 14) {
          ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
            CopyCard(
              file: file, kind: DuplicateKind(path: file.path), folder: dup.folderName(file),
              isKept: file.path == keep, index: index
            ) {
              withAnimation(Motion.resolve(Motion.bouncy)) { dup.keep(file, in: group) }
            }
          }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 4)
      }
      .scrollClipDisabled()
      .id(group.id)
      .padding(.horizontal, -4)

      footer
    }
    .padding(.horizontal, 22)
    .padding(.top, 20)
    .padding(.bottom, 18)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color.sectorCard.opacity(0.75), in: .rect(cornerRadius: Metrics.cardRadius))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.cardRadius)
        .strokeBorder(Color.sectorHairline, lineWidth: 0.5)
    )
  }

  private var footer: some View {
    let removed = group.files.count - 1
    let groups = Plural.format(dup.groups.count, "группе", "группам", "группам")
    let total = ByteFormat.string(dup.totalWaste)
    let destination =
      model.settings.moveToTrash
      ? String(localized: "Копии попадут в Корзину")
      : String(localized: "Копии будут удалены навсегда")
    return HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 1) {
        Text("Будет удалено копий: \(removed) · \(ByteFormat.string(dup.waste(group)))")
          .font(.system(size: 13, weight: .semibold))
          .monospacedDigit()
          .contentTransition(.numericText())
        Text("\(destination) · всего по \(groups) — \(total)")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .contentTransition(.numericText())
      }
      Spacer(minLength: 8)
      if !dup.showsAllGroups, dup.groups.count > DuplicatesModel.initialLimit {
        Button("Все группы") {
          withAnimation(Motion.resolve(Motion.smooth)) { dup.showsAllGroups = true }
        }
        .buttonStyle(.glass)
      }
      Button("Удалить копии") { dup.deleteCopies() }
        .buttonStyle(.glassProminent)
        .disabled(dup.copiesToDelete.isEmpty)
    }
    .controlSize(.large)
    .padding(.leading, 18)
    .padding(.trailing, 12)
    .padding(.vertical, 12)
    .background(Color.sectorCard, in: .rect(cornerRadius: 18))
    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.sectorHairline, lineWidth: 0.5))
    .shadow(color: Color(hex: 0x141E46).opacity(0.07), radius: 9, y: 6)
  }

  private var detail: String {
    let copies = Plural.format(
      group.files.count, "одинаковая копия", "одинаковые копии", "одинаковых копий")
    return String(localized: "\(copies) · по \(ByteFormat.string(group.size))")
  }
}

/// One copy: thumbnail with a "Оставить" / "Удалить" badge, folder, path,
/// date and size. Deals in like a card and lifts on hover.
private struct CopyCard: View {
  @Environment(AppModel.self) private var model
  var file: DuplicateFile
  var kind: DuplicateKind
  var folder: String
  var isKept: Bool
  var index: Int
  var action: () -> Void

  @State private var appeared = false
  @State private var hovering = false

  private static let cardFill = Color(light: 0xFFFFFF, dark: 0x2C2C30)
  private static let keptColor = Color(hex: 0x34C759)

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 0) {
        thumbnail
        VStack(alignment: .leading, spacing: 1) {
          Text(folder)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
          Text((file.directory as NSString).abbreviatingWithTildeInPath)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          HStack {
            Text(file.created.formatted(.dateTime.day().month(.abbreviated).year()))
            Spacer(minLength: 4)
            SizeText(bytes: file.size, font: .system(size: 11))
          }
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .padding(.top, 5)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
      }
      .background(Self.cardFill)
      .clipShape(.rect(cornerRadius: 18))
      .overlay {
        RoundedRectangle(cornerRadius: 18)
          .strokeBorder(
            isKept ? Self.keptColor : Color.primary.opacity(0.08), lineWidth: isKept ? 2.5 : 0.5)
      }
      .shadow(
        color: isKept ? Self.keptColor.opacity(0.22) : Color(hex: 0x141E46).opacity(0.08),
        radius: isKept ? 14 : 9, y: isKept ? 12 : 6
      )
      .opacity(isKept ? 1 : 0.88)
      .contentShape(.rect(cornerRadius: 18))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("Оставить копию из папки \(folder)"))
    .accessibilityAddTraits(isKept ? .isSelected : [])
    .help(file.path)
    .contextMenu {
      Button("Показать в Finder") { model.revealInFinder([file.url]) }
    }
    .offset(y: hovering && !Motion.reduced ? -4 : 0)
    .rotationEffect(.degrees(hovering && !Motion.reduced ? -0.5 : 0))
    .onHover { hover in
      withAnimation(Motion.resolve(.spring(duration: 0.4, bounce: 0.3))) { hovering = hover }
    }
    // Deal-in: each card flies in from the lower left, one after another.
    .opacity(appeared ? 1 : 0)
    .scaleEffect(appeared || Motion.reduced ? 1 : 0.8)
    .rotationEffect(.degrees(appeared || Motion.reduced ? 0 : -14))
    .offset(x: appeared || Motion.reduced ? 0 : -120, y: appeared || Motion.reduced ? 0 : 40)
    .onAppear {
      withAnimation(
        Motion.resolve(.spring(duration: 0.7, bounce: 0.25)).delay(
          Motion.reduced ? 0 : Motion.stagger(index, step: 0.11))
      ) { appeared = true }
    }
  }

  private var thumbnail: some View {
    ZStack(alignment: .topLeading) {
      Rectangle().fill(kind.background)
      if kind.isMedia {
        FileThumbnail(path: file.path, side: 260)
      } else {
        FileThumbnail(path: file.path, side: 120, contentMode: .fit)
          .frame(width: 76, height: 98)
          .shadow(color: .black.opacity(0.18), radius: 8, y: 6)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if kind == .video {
        Image(systemName: "play.fill")
          .font(.system(size: 14))
          .foregroundStyle(Color(hex: 0x1D1D1F))
          .frame(width: 38, height: 38)
          .background(.white.opacity(0.85), in: .circle)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      badge.padding(10)
      if file.isClone {
        Text("Клон")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(.black.opacity(0.35), in: .capsule)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .topTrailing)
          .help("APFS-клон: данные общие с другой копией, удаление почти не освободит места")
      }
    }
    .frame(height: 130)
    .frame(maxWidth: .infinity)
    .clipped()
    .saturation(isKept ? 1 : 0.75)
  }

  private var badge: some View {
    ZStack {
      if isKept {
        Label("Оставить", systemImage: "star.fill")
          .transition(.scale(scale: 0, anchor: .center).combined(with: .opacity))
      } else {
        Label("Удалить", systemImage: "xmark")
          .transition(.scale(scale: 0, anchor: .center).combined(with: .opacity))
      }
    }
    .labelStyle(BadgeLabelStyle())
    .font(.system(size: 11, weight: .bold))
    .foregroundStyle(.white)
    .padding(.horizontal, 9)
    .padding(.vertical, 4)
    .background {
      RoundedRectangle(cornerRadius: 10)
        .fill(isKept ? Color(hex: 0x28A745) : Color.black.opacity(0.45))
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
    }
    .animation(Motion.resolve(Motion.bouncy), value: isKept)
  }
}

private struct BadgeLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.icon.font(.system(size: 9, weight: .heavy))
      configuration.title
    }
  }
}

// MARK: - Progress and empty states

private struct DuplicatesProgressView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let progress = model.duplicates.progress
    VStack(spacing: 16) {
      ZStack {
        ProgressRing(fraction: progress.fraction, lineWidth: 9)
          .animation(Motion.resolve(Motion.smooth), value: progress.fraction)
        Image(systemName: "square.on.square")
          .font(.system(size: 28, weight: .medium))
          .foregroundStyle(Color.sectorAccent)
          .symbolEffect(.pulse, options: .repeat(.continuous), isActive: !Motion.reduced)
      }
      .frame(width: 96, height: 96)

      VStack(spacing: 4) {
        Text(title).font(.system(size: 17, weight: .bold))
        Text(detail(progress))
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .contentTransition(.numericText())
      }
      Button("Отменить") { model.duplicates.cancel() }
        .buttonStyle(.glass)
        .controlSize(.large)
    }
    .padding(32)
    .frame(width: 420)
    .background(Color.sectorCard, in: .rect(cornerRadius: Metrics.windowRadius))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.windowRadius)
        .strokeBorder(Color.sectorHairline, lineWidth: 0.5)
    )
    .shadow(color: Color(hex: 0x141E46).opacity(0.12), radius: 30, y: 12)
    .appearAnimation()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var title: LocalizedStringKey {
    switch model.duplicates.progress.phase {
    case .collecting: return "Собираем файлы"
    case .comparing: return "Сравниваем файлы одного размера"
    case .hashing, .finished: return "Проверяем содержимое · SHA-256"
    }
  }

  private func detail(_ p: DuplicateProgress) -> String {
    guard p.phase != .collecting else {
      return String(localized: "Ищем файлы больше 1 МБ")
    }
    let files = Plural.format(p.candidates, "файл", "файла", "файлов")
    return String(
      localized:
        "\(ByteFormat.string(p.hashedBytes)) из \(ByteFormat.string(p.totalBytes)) · \(files)")
  }
}

/// "Дубликатов не найдено" from design/mockups/States.dc.html.
private struct NoDuplicatesView: View {
  @Environment(AppModel.self) private var model
  @State private var spin = false
  @State private var float = false
  @State private var twinkle = false

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        Circle()
          .strokeBorder(
            Color(hex: 0x34C759).opacity(0.35),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 7]))
          .rotationEffect(.degrees(spin ? 360 : 0))
        Circle()
          .fill(Color(hex: 0x34C759).opacity(0.14))
          .padding(14)
          .overlay {
            Image(systemName: "checkmark.square")
              .font(.system(size: 30, weight: .regular))
              .foregroundStyle(Color.sectorSuccess)
              .overlay(alignment: .topLeading) {
                Image(systemName: "square")
                  .font(.system(size: 22, weight: .regular))
                  .foregroundStyle(Color.sectorSuccess.opacity(0.6))
                  .offset(x: -9, y: -9)
              }
          }
          .offset(y: float ? -4 : 2)
        sparkle(14, Color(hex: 0xFFCC00))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          .padding(.top, 6)
          .padding(.trailing, 2)
        sparkle(10, Color(hex: 0x30B0C7))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
          .padding(.bottom, 12)
          .padding(.leading, 4)
      }
      .frame(width: 96, height: 96)
      .accessibilityHidden(true)

      Text("Дубликатов не найдено")
        .font(.system(size: 17, weight: .bold))
        .padding(.top, 16)
      Text(message)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 340)
        .padding(.top, 4)
      Button("Проверить весь диск") {
        if model.settings.scanScope == .home { model.settings.scanScope = .startupDisk }
        model.startScan()
      }
      .buttonStyle(.glass)
      .controlSize(.large)
      .padding(.top, 16)
    }
    .padding(24)
    .frame(width: 520, height: 300)
    .background(Color.sectorCard, in: .rect(cornerRadius: Metrics.windowRadius))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.windowRadius)
        .strokeBorder(Color.sectorHairline, lineWidth: 0.5)
    )
    .shadow(color: Color(hex: 0x141E46).opacity(0.14), radius: 30, y: 12)
    .appearAnimation()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      guard !Motion.reduced else { return }
      withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) { spin = true }
      withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { float = true }
      withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { twinkle = true }
    }
  }

  private var message: String {
    if model.tree?.rootPath == NSHomeDirectory() {
      return String(
        localized: "В домашней папке все файлы уникальны. Можно проверить весь диск.")
    }
    return String(localized: "Все файлы больше 1 МБ уникальны. Можно проверить диск ещё раз.")
  }

  private func sparkle(_ size: CGFloat, _ color: Color) -> some View {
    Image(systemName: "sparkle")
      .font(.system(size: size, weight: .bold))
      .foregroundStyle(color)
      .scaleEffect(twinkle ? 0.75 : 1)
      .rotationEffect(.degrees(twinkle ? 20 : 0))
  }
}
