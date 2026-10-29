import AppKit
import SectorCore
import ServiceManagement
import SwiftUI

/// Settings window (design/mockups/Settings.dc.html): native tabs, every
/// control bound to `AppSettings`.
struct SettingsView: View {
  enum Pane: Hashable { case general, scanning, cleaning, notifications, exclusions }

  @State private var pane: Pane = .general

  var body: some View {
    TabView(selection: $pane) {
      Tab("Основные", systemImage: "gearshape", value: .general) {
        GeneralPane().frame(height: 410)
      }
      Tab("Сканирование", systemImage: "magnifyingglass", value: .scanning) {
        ScanningPane().frame(height: 440)
      }
      Tab("Очистка", systemImage: "sparkles", value: .cleaning) {
        CleaningPane().frame(height: 360)
      }
      Tab("Уведомления", systemImage: "bell", value: .notifications) {
        NotificationsPane().frame(height: 430)
      }
      Tab("Исключения", systemImage: "nosign", value: .exclusions) {
        ExclusionsPane().frame(height: 400)
      }
    }
    .frame(width: 620)
    .capturesOpenWindow()
  }
}

// MARK: - Основные

private struct GeneralPane: View {
  @Environment(AppModel.self) private var model
  @State private var loginError: String?
  @State private var needsApproval = false

  var body: some View {
    @Bindable var settings = model.settings
    Form {
      Section {
        Toggle("Открывать при входе в систему", isOn: launchAtLogin)
        if needsApproval || loginError != nil {
          HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(needsApproval ? Color.sectorWarning : Color.sectorDanger)
            Text(loginError ?? String(localized: "Разрешите Sector в Системных настройках › Объекты входа."))
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
            Spacer()
            if needsApproval {
              Button("Открыть") { SMAppService.openSystemSettingsLoginItems() }
                .controlSize(.small)
            }
          }
          .transition(.opacity.combined(with: .offset(y: -4)))
        }
        Toggle("Показывать в строке меню", isOn: $settings.showInMenuBar)
        LabeledContent("Значок в строке меню") {
          MenuBarStylePicker(
            style: $settings.menuBarStyle, volume: model.volume)
        }
      }
      Section {
        Picker("Единицы размера", selection: $settings.binaryUnits) {
          Text("Десятичные (ГБ = 1000 МБ)").tag(false)
          Text("Двоичные (ГБ = 1024 МБ)").tag(true)
        }
        Toggle(isOn: $settings.animationsEnabled) {
          Text("Анимации интерфейса")
          Text("Учитывает «Уменьшить движение» в системе")
        }
      } footer: {
        VersionLine().padding(.top, 8)
      }
    }
    .formStyle(.grouped)
    .animation(Motion.resolve(Motion.smooth), value: needsApproval)
    .animation(Motion.resolve(Motion.smooth), value: loginError)
    .appearAnimation(offset: 10)
    .onAppear(perform: syncLoginStatus)
  }

  /// Mirrors `SMAppService.mainApp`, the source of truth for login items.
  private var launchAtLogin: Binding<Bool> {
    Binding(
      get: { model.settings.launchAtLogin },
      set: { enabled in
        loginError = nil
        do {
          if enabled {
            try SMAppService.mainApp.register()
          } else {
            try SMAppService.mainApp.unregister()
          }
        } catch {
          loginError = String(
            localized: "Не удалось изменить объекты входа: \(error.localizedDescription)")
        }
        syncLoginStatus()
        if enabled, loginError == nil, !needsApproval, !model.settings.launchAtLogin {
          loginError = String(localized: "macOS не добавила Sector в объекты входа.")
        }
      })
  }

  private func syncLoginStatus() {
    let status = SMAppService.mainApp.status
    needsApproval = status == .requiresApproval
    model.settings.launchAtLogin = status == .enabled || status == .requiresApproval
  }
}

/// Segmented control of the three icon styles, each with a live preview.
private struct MenuBarStylePicker: View {
  @Binding var style: AppSettings.MenuBarStyle
  var volume: VolumeInfo?
  @Namespace private var namespace

  var body: some View {
    HStack(spacing: 0) {
      ForEach(AppSettings.MenuBarStyle.allCases, id: \.self) { option in
        Button {
          withAnimation(Motion.resolve(Motion.bouncy)) { style = option }
        } label: {
          VStack(spacing: 4) {
            preview(option).frame(height: 16)
            Text(title(option)).font(.system(size: 11, weight: .medium))
          }
          .frame(width: 96, height: 46)
          .background {
            if style == option {
              RoundedRectangle(cornerRadius: 7)
                .fill(Color(light: 0xFFFFFF, dark: 0x636366))
                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                .matchedGeometryEffect(id: "pill", in: namespace)
            }
          }
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(style == option ? .isSelected : [])
      }
    }
    .padding(2)
    .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 9))
  }

  private func title(_ option: AppSettings.MenuBarStyle) -> LocalizedStringKey {
    switch option {
    case .ring: return "Кольцо"
    case .ringAndSize: return "Кольцо + ГБ"
    case .sizeOnly: return "Только ГБ"
    }
  }

  @ViewBuilder private func preview(_ option: AppSettings.MenuBarStyle) -> some View {
    let percent = Int(((volume?.usedFraction ?? 0.88) * 100).rounded())
    let ring = Image(nsImage: MenuBarRing.image(percent: percent)).renderingMode(.template)
    let free = Text(volume.map { ByteFormat.string($0.available) } ?? "—")
      .font(.system(size: 11, weight: .semibold))
      .monospacedDigit()
    HStack(spacing: 4) {
      switch option {
      case .ring: ring
      case .ringAndSize:
        ring
        free
      case .sizeOnly: free
      }
    }
    .foregroundStyle(style == option ? .primary : .secondary)
  }
}

private struct VersionLine: View {
  var body: some View {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
    let build = info["CFBundleVersion"] as? String ?? "1"
    HStack(spacing: 10) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 28, height: 28)
      Text("Sector \(version) (\(build))")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Сканирование

private struct ScanningPane: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var settings = model.settings
    let volumes = model.volumes
    Form {
      Section("Диски для анализа") {
        ForEach(volumes) { volume in
          DriveRow(
            name: volume.name, detail: detail(volume), isOn: binding(for: volume),
            locked: volume.url.path == "/")
        }
        if !volumes.contains(where: { !$0.isNetwork && $0.url.path != "/" }) {
          DriveRow(
            name: String(localized: "Внешние диски"), detail: String(localized: "не подключены"),
            isOn: $settings.includeExternalDrives)
        }
        if !volumes.contains(where: \.isNetwork) {
          DriveRow(
            name: String(localized: "Сетевые диски"), detail: String(localized: "медленнее"),
            isOn: $settings.includeNetworkDrives)
        }
      }
      Section {
        Toggle("Учитывать скрытые файлы", isOn: $settings.includeHidden)
        Picker("Сканировать в фоне", selection: $settings.backgroundScan) {
          Text("Раз в неделю").tag(true)
          Text("Никогда").tag(false)
        }
        LabeledContent {
          Slider(value: load, in: 0...2, step: 1) {
            Text("Нагрузка на систему")
          } minimumValueLabel: {
            Image(systemName: "tortoise").foregroundStyle(.secondary)
          } maximumValueLabel: {
            Image(systemName: "hare").foregroundStyle(.secondary)
          }
          .labelsHidden()
          .frame(width: 220)
        } label: {
          Text("Нагрузка на систему")
          Text(loadLabel(settings.scanLoad))
            .contentTransition(.opacity)
            .animation(Motion.resolve(Motion.quick), value: settings.scanLoad)
        }
      }
    }
    .formStyle(.grouped)
    .appearAnimation(offset: 10)
  }

  private func binding(for volume: VolumeInfo) -> Binding<Bool> {
    @Bindable var settings = model.settings
    if volume.url.path == "/" { return .constant(true) }
    return volume.isNetwork ? $settings.includeNetworkDrives : $settings.includeExternalDrives
  }

  private func detail(_ volume: VolumeInfo) -> String {
    if volume.isNetwork { return String(localized: "медленнее") }
    let fs: String =
      switch volume.fileSystem {
      case "EXFAT": "exFAT"
      case "MSDOS": "FAT32"
      default: volume.fileSystem
      }
    return fs.isEmpty
      ? ByteFormat.string(volume.total) : "\(ByteFormat.string(volume.total)) · \(fs)"
  }

  private var load: Binding<Double> {
    Binding(
      get: { Double(ScanLoad.allCases.firstIndex(of: model.settings.scanLoad) ?? 1) },
      set: { value in
        let index = max(0, min(ScanLoad.allCases.count - 1, Int(value.rounded())))
        model.settings.scanLoad = ScanLoad.allCases[index]
      })
  }

  private func loadLabel(_ load: ScanLoad) -> LocalizedStringKey {
    switch load {
    case .gentle: return "Бережно — медленнее, почти не заметно"
    case .balanced: return "Сбалансированно"
    case .maximum: return "Максимально быстро — может греться"
    }
  }
}

private struct DriveRow: View {
  var name: String
  var detail: String
  @Binding var isOn: Bool
  var locked = false

  var body: some View {
    HStack {
      Toggle(isOn: $isOn) { Text(name) }
        .toggleStyle(.checkbox)
        .disabled(locked)
      Spacer()
      Text(detail)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }
}

// MARK: - Очистка

private struct CleaningPane: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var settings = model.settings
    Form {
      Section {
        Toggle(isOn: $settings.moveToTrash) {
          Text("Перемещать в Корзину вместо удаления")
          Text("Рекомендуется: всё можно вернуть из «Истории»")
        }
        LabeledContent("Хранить удалённое") {
          DayStepper(days: $settings.keepDays)
        }
        Picker("Не предлагать файлы моложе", selection: $settings.minimumAgeDays) {
          ForEach(ageOptions(current: settings.minimumAgeDays), id: \.self) { days in
            Text(Plural.format(days, "день", "дня", "дней")).tag(days)
          }
        }
        Toggle("Всегда спрашивать подтверждение", isOn: $settings.alwaysConfirm)
      } footer: {
        if !settings.moveToTrash {
          HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
              .font(.system(size: 14, weight: .semibold))
            Text("Файлы будут удаляться сразу. Восстановить их не получится.")
              .font(.system(size: 12))
            Spacer(minLength: 0)
          }
          .foregroundStyle(Color.sectorDanger)
          .padding(.horizontal, 14)
          .padding(.vertical, 12)
          .background(Color.sectorDanger.opacity(0.08), in: .rect(cornerRadius: 14))
          .padding(.top, 8)
          .transition(.opacity.combined(with: .offset(y: 10)))
          .accessibilityAddTraits(.isStaticText)
        }
      }
    }
    .formStyle(.grouped)
    .animation(Motion.resolve(Motion.smooth), value: settings.moveToTrash)
    .appearAnimation(offset: 10)
  }

  private func ageOptions(current: Int) -> [Int] {
    Array(Set([7, 30, 60, 90, 180, 365, current])).sorted()
  }
}

/// "− 30 дней +" capsule from the mock.
private struct DayStepper: View {
  @Binding var days: Int
  private static let steps = [7, 14, 30, 60, 90]

  var body: some View {
    HStack(spacing: 2) {
      stepButton("minus", label: "Меньше дней", target: Self.steps.last { $0 < days })
      Text(Plural.format(days, "день", "дня", "дней"))
        .font(.system(size: 12, weight: .semibold))
        .monospacedDigit()
        .contentTransition(.numericText(value: Double(days)))
        .frame(width: 70)
      stepButton("plus", label: "Больше дней", target: Self.steps.first { $0 > days })
    }
    .padding(2)
    .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 9))
  }

  private func stepButton(_ symbol: String, label: LocalizedStringKey, target: Int?) -> some View {
    Button {
      guard let target else { return }
      withAnimation(Motion.resolve(Motion.bouncy)) { days = target }
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold))
        .frame(width: 26, height: 24)
        .contentShape(.rect)
    }
    .buttonStyle(StepperPressStyle())
    .disabled(target == nil)
    .accessibilityLabel(Text(label))
  }
}

private struct StepperPressStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        Color.primary.opacity(configuration.isPressed ? 0.1 : 0), in: .rect(cornerRadius: 7)
      )
      .opacity(isEnabled ? 1 : 0.35)
      .scaleEffect(configuration.isPressed ? 0.92 : 1)
      .animation(Motion.resolve(Motion.quick), value: configuration.isPressed)
  }
}

// MARK: - Уведомления

private struct NotificationsPane: View {
  @Environment(AppModel.self) private var model
  @State private var denied = false

  var body: some View {
    @Bindable var settings = model.settings
    Form {
      Section {
        LabeledContent {
          HStack(spacing: 12) {
            Slider(value: threshold, in: 10...100, step: 5) {
              Text("Порог свободного места, ГБ")
            }
            .labelsHidden()
            .frame(width: 190)
            .disabled(!settings.lowSpaceWarning)
            Toggle("Предупреждать о нехватке места", isOn: $settings.lowSpaceWarning)
              .labelsHidden()
              .toggleStyle(.switch)
          }
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text("Предупреждать, когда свободно меньше")
            Text("\(settings.lowSpaceThresholdGB) ГБ")
              .font(.system(size: 20, weight: .bold))
              .foregroundStyle(settings.lowSpaceWarning ? Color.sectorAccent : .secondary)
              .monospacedDigit()
              .contentTransition(.numericText(value: Double(settings.lowSpaceThresholdGB)))
              .animation(Motion.resolve(Motion.quick), value: settings.lowSpaceThresholdGB)
          }
        }
        Toggle("Ежемесячный отчёт о диске", isOn: $settings.monthlyReport)
        Toggle("Сообщать о больших новых файлах (> 5 ГБ)", isOn: $settings.notifyLargeFiles)
      } footer: {
        VStack(alignment: .leading, spacing: 10) {
          Text("Так будет выглядеть уведомление")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
          NotificationPreview(
            message: NotificationService.lowSpaceMessage(
              volumeName: model.volume?.name ?? "Macintosh HD",
              available: AppModel.bytes(gigabytes: settings.lowSpaceThresholdGB),
              limitGB: settings.lowSpaceThresholdGB,
              reclaimable: model.smartClean.reclaimableBytes, critical: false))
          if denied {
            HStack(spacing: 8) {
              Image(systemName: "bell.slash").foregroundStyle(Color.sectorWarning)
              Text("Уведомления Sector выключены в Системных настройках.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
              Spacer()
              Button("Открыть", action: openNotificationSettings).controlSize(.small)
            }
            .padding(.horizontal, 4)
          }
        }
        .padding(.top, 12)
      }
    }
    .formStyle(.grouped)
    .appearAnimation(offset: 10)
    .task { denied = await NotificationService.isDenied() }
  }

  private var threshold: Binding<Double> {
    Binding(
      get: { Double(model.settings.lowSpaceThresholdGB) },
      set: { model.settings.lowSpaceThresholdGB = Int($0.rounded()) })
  }

  private func openNotificationSettings() {
    let id = Bundle.main.bundleIdentifier ?? "com.kewldan.sector"
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
    {
      NSWorkspace.shared.open(url)
    }
  }
}

/// Live preview of the low-space notification; slides in like a banner.
private struct NotificationPreview: View {
  var message: (title: String, body: String)
  @State private var shown = false

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 36, height: 36)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline) {
          Text(message.title).font(.system(size: 13, weight: .bold))
          Spacer()
          Text("сейчас").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        Text(message.body)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .contentTransition(.numericText())
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(.regularMaterial, in: .rect(cornerRadius: 20))
    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.sectorHairline, lineWidth: 0.5))
    .shadow(color: Color(hex: 0x141E46).opacity(0.12), radius: 15, y: 10)
    .opacity(shown ? 1 : 0)
    .offset(x: shown || Motion.reduced ? 0 : 40)
    .animation(Motion.resolve(Motion.quick), value: message.body)
    .onAppear {
      withAnimation(stagedAnimation(.spring(duration: 0.6, bounce: 0.3), delay: 0.2)) {
        shown = true
      }
    }
  }
}

// MARK: - Исключения

private struct ExclusionsPane: View {
  @Environment(AppModel.self) private var model
  @State private var added: String?

  var body: some View {
    let exclusions = model.settings.exclusions
    Form {
      Section {
        if exclusions.isEmpty {
          Text("Исключений пока нет")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 32)
        }
        ForEach(exclusions, id: \.self) { path in
          ExclusionRow(path: path, isNew: path == added) { remove(path) }
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
      } header: {
        Text("Sector не будет анализировать и предлагать к удалению файлы из этих папок.")
          .font(.system(size: 12, weight: .regular))
          .foregroundStyle(.secondary)
          .textCase(nil)
      } footer: {
        Button(action: addFolders) {
          Label("Добавить папку…", systemImage: "plus")
            .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.glass)
        .padding(.top, 8)
      }
    }
    .formStyle(.grouped)
    .appearAnimation(offset: 10)
  }

  private func remove(_ path: String) {
    withAnimation(Motion.resolve(Motion.smooth)) {
      model.settings.exclusions.removeAll { $0 == path }
    }
  }

  private func addFolders() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = String(localized: "Исключить")
    panel.message = String(localized: "Выберите папки, которые Sector не будет трогать")
    guard panel.runModal() == .OK else { return }
    var list = model.settings.exclusions
    var last: String?
    for url in panel.urls {
      let path = url.standardizedFileURL.path
      guard !list.contains(path) else { continue }
      list.append(path)
      last = path
    }
    guard let last else { return }
    added = last
    withAnimation(Motion.resolve(Motion.bouncy)) { model.settings.exclusions = list }
    Task {
      try? await Task.sleep(for: .seconds(3))
      if added == last { added = nil }
    }
  }
}

private struct ExclusionRow: View {
  var path: String
  var isNew: Bool
  var remove: () -> Void
  @State private var highlight = false

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "folder.fill")
        .font(.system(size: 15))
        .foregroundStyle(Color(hex: 0x5AC8FA))
      Text((path as NSString).abbreviatingWithTildeInPath)
        .font(.sectorPath)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
          .background(Color.primary.opacity(0.05), in: .circle)
          .contentShape(.circle)
      }
      .buttonStyle(StepperPressStyle())
      .accessibilityLabel(Text("Убрать \(path)"))
    }
    .padding(.vertical, 2)
    .background {
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.sectorAccent.opacity(highlight ? 0.08 : 0))
        .padding(.horizontal, -10)
        .padding(.vertical, -6)
    }
    .onAppear {
      guard isNew else { return }
      highlight = true
      withAnimation(.easeOut(duration: 1.6).delay(0.6)) { highlight = false }
    }
  }
}
