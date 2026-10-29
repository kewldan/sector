import AppKit
import SectorCore
@preconcurrency import UserNotifications

/// User notifications: low space, big new files after a background scan and
/// the monthly report. Authorization is requested the first time Sector has
/// something to say. Actions open the main window (Smart Clean by default).
@MainActor
final class NotificationService: NSObject {
  private enum Category {
    static let space = "sector.space"
    static let files = "sector.files"
    static let report = "sector.report"
  }

  private enum Action {
    static let clean = "sector.clean"
    static let details = "sector.details"
  }

  private enum Key {
    static let lowSpace = "notify.lowSpace.last"
    static let monthly = "notify.monthly.month"
  }

  private let model: AppModel
  private let defaults = UserDefaults.standard

  init(model: AppModel) {
    self.model = model
  }

  /// UNUserNotificationCenter traps outside an app bundle (`swift run`).
  private static var center: UNUserNotificationCenter? {
    Bundle.main.bundleIdentifier == nil ? nil : .current()
  }

  func start() {
    guard let center = Self.center else { return }
    center.delegate = self
    let clean = UNNotificationAction(
      identifier: Action.clean, title: String(localized: "Очистить"), options: [.foreground])
    let details = UNNotificationAction(
      identifier: Action.details, title: String(localized: "Подробнее"), options: [.foreground])
    let review = UNNotificationAction(
      identifier: Action.details, title: String(localized: "Посмотреть"), options: [.foreground])
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: Category.space, actions: [clean, details], intentIdentifiers: []),
      UNNotificationCategory(identifier: Category.files, actions: [review], intentIdentifiers: []),
      UNNotificationCategory(
        identifier: Category.report, actions: [details], intentIdentifiers: []),
    ])
  }

  // MARK: - Authorization

  /// Whether the user turned Sector's notifications off in System Settings.
  static func isDenied() async -> Bool {
    guard let center else { return false }
    return await center.notificationSettings().authorizationStatus == .denied
  }

  private func authorize() async -> Bool {
    guard let center = Self.center else { return false }
    switch await center.notificationSettings().authorizationStatus {
    case .authorized, .provisional: return true
    case .notDetermined:
      return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    default: return false
    }
  }

  private func post(
    id: String, title: String, body: String, category: String, route: Route
  ) async {
    guard await authorize(), let center = Self.center else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.categoryIdentifier = category
    content.sound = .default
    content.userInfo = ["route": route.rawValue]
    try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
  }

  // MARK: - Low space

  /// Title and body of the low-space notification; Settings previews it.
  static func lowSpaceMessage(
    volumeName: String, available: UInt64, limitGB: Int, reclaimable: UInt64, critical: Bool
  ) -> (title: String, body: String) {
    let free = ByteFormat.string(available)
    let found = ByteFormat.string(reclaimable)
    if critical {
      let body =
        reclaimable > 0
        ? String(localized: "На \(volumeName) осталось \(free). Sector может освободить \(found) за минуту.")
        : String(localized: "На \(volumeName) осталось \(free). Откройте Sector, чтобы освободить место.")
      return (String(localized: "Почти нет места"), body)
    }
    let body =
      reclaimable > 0
      ? String(localized: "Свободно меньше \(limitGB) ГБ. Sector нашёл \(found), которые можно освободить.")
      : String(localized: "Свободно меньше \(limitGB) ГБ. Откройте Sector, чтобы найти, что можно удалить.")
    return (String(localized: "Мало места на \(volumeName)"), body)
  }

  /// Warns once a day while free space stays under the user's threshold.
  func checkLowSpace(_ volume: VolumeInfo?) {
    let settings = model.settings
    guard settings.lowSpaceWarning, let volume, volume.total > 0 else { return }
    guard volume.available < AppModel.bytes(gigabytes: settings.lowSpaceThresholdGB) else { return }
    if let last = defaults.object(forKey: Key.lowSpace) as? Date,
      Calendar.current.isDateInToday(last)
    {
      return
    }
    defaults.set(Date(), forKey: Key.lowSpace)
    let message = Self.lowSpaceMessage(
      volumeName: volume.name, available: volume.available,
      limitGB: settings.lowSpaceThresholdGB, reclaimable: model.smartClean.reclaimableBytes,
      critical: Double(volume.available) < Double(volume.total) * 0.05)
    Task {
      await post(
        id: "sector.lowSpace", title: message.title, body: message.body,
        category: Category.space, route: .smartClean)
    }
  }

  // MARK: - Large new files

  /// After a background scan: files of 5 GB or more modified since `since`.
  func reportNewLargeFiles(in tree: FileTree, since: Date) async {
    guard model.settings.notifyLargeFiles else { return }
    let minimum = AppModel.bytes(gigabytes: 5)
    let found = await Task.detached(priority: .utility) { () -> [(path: String, size: UInt64)] in
      tree.files(atLeast: minimum)
        .filter { tree.modificationDate($0) > since }
        .map { (tree.path($0), tree.size($0)) }
        .sorted { $0.size > $1.size }
    }.value
    let files = found.filter { !model.settings.isExcluded($0.path) }
    guard let first = files.first else { return }
    let title: String
    let body: String
    if files.count == 1 {
      let name = (first.path as NSString).lastPathComponent
      title = String(localized: "Новый большой файл")
      body = String(localized: "\(name) занимает \(ByteFormat.string(first.size)).")
    } else {
      let total = files.reduce(0) { $0 + $1.size }
      let count = Plural.format(files.count, "файл", "файла", "файлов")
      title = String(localized: "Новые большие файлы")
      body = String(localized: "Появилось \(count) больше 5 ГБ — всего \(ByteFormat.string(total)).")
    }
    await post(
      id: "sector.largeFiles", title: title, body: body, category: Category.files,
      route: .largeFiles)
  }

  // MARK: - Monthly report

  /// Posts the report (or the reminder) once when a new month starts.
  func checkMonthly(now: Date = Date()) {
    let settings = model.settings
    guard settings.monthlyReport || settings.monthlyReminder else { return }
    let calendar = Calendar.current
    let parts = calendar.dateComponents([.year, .month], from: now)
    let month = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    // The first month after turning it on only sets the baseline.
    guard let last = defaults.string(forKey: Key.monthly) else {
      defaults.set(month, forKey: Key.monthly)
      return
    }
    guard last != month else { return }
    defaults.set(month, forKey: Key.monthly)

    if settings.monthlyReport, let volume = model.volume {
      let previous = calendar.date(byAdding: .month, value: -1, to: now) ?? now
      let formatter = DateFormatter()
      formatter.setLocalizedDateFormatFromTemplate("LLLL")
      let monthName = formatter.string(from: previous)
      let freed = model.history.freed(since: now.addingTimeInterval(-30 * 86_400))
      var body = String(
        localized:
          "Освобождено \(ByteFormat.string(freed)). Свободно \(ByteFormat.string(volume.available)) из \(ByteFormat.string(volume.total)).")
      if let days = model.history.daysUntilFull(available: volume.available),
        days < ForecastText.horizonDays
      {
        body += " " + String(localized: "Заполнится примерно через \(ForecastText.duration(days: days)).")
      }
      Task {
        await post(
          id: "sector.monthly", title: String(localized: "Отчёт о диске за \(monthName)"),
          body: body, category: Category.report, route: .overview)
      }
    } else {
      let reclaimable = model.smartClean.reclaimableBytes
      let body =
        reclaimable > 0
        ? String(localized: "Sector нашёл \(ByteFormat.string(reclaimable)), которые можно освободить.")
        : String(localized: "Проверьте, что занимает место на диске.")
      Task {
        await post(
          id: "sector.monthly", title: String(localized: "Пора навести порядок"), body: body,
          category: Category.space, route: .smartClean)
      }
    }
  }

  // MARK: - Responses

  fileprivate func handle(action: String, route: String?) {
    if action == Action.clean {
      model.startQuickClean()
    } else {
      model.presentInMainWindow(route.flatMap(Route.init(rawValue:)) ?? .smartClean)
    }
  }
}

extension NotificationService: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let action = response.actionIdentifier
    guard action != UNNotificationDismissActionIdentifier else { return }
    let route = response.notification.request.content.userInfo["route"] as? String
    await MainActor.run { self.handle(action: action, route: route) }
  }
}
