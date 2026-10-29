import Foundation
import Observation
import SectorCore

/// User preferences, persisted in `UserDefaults`. Every screen reads these;
/// the Settings window edits them.
@Observable @MainActor
final class AppSettings {
  enum MenuBarStyle: String, CaseIterable, Codable {
    case ring, ringAndSize, sizeOnly
  }

  enum ScanScope: String, Codable {
    /// The whole startup disk ("/").
    case startupDisk
    /// Only the home folder, when Full Disk Access is declined.
    case home
  }

  private let defaults: UserDefaults

  // General
  var launchAtLogin: Bool { didSet { save(launchAtLogin, "launchAtLogin") } }
  var showInMenuBar: Bool { didSet { save(showInMenuBar, "showInMenuBar") } }
  var menuBarStyle: MenuBarStyle { didSet { save(menuBarStyle.rawValue, "menuBarStyle") } }
  var binaryUnits: Bool {
    didSet {
      save(binaryUnits, "binaryUnits")
      ByteFormat.base = binaryUnits ? 1024 : 1000
    }
  }
  var animationsEnabled: Bool { didSet { save(animationsEnabled, "animationsEnabled") } }

  // Scanning
  var scanScope: ScanScope { didSet { save(scanScope.rawValue, "scanScope") } }
  var includeExternalDrives: Bool { didSet { save(includeExternalDrives, "includeExternal") } }
  var includeNetworkDrives: Bool { didSet { save(includeNetworkDrives, "includeNetwork") } }
  var includeHidden: Bool { didSet { save(includeHidden, "includeHidden") } }
  var backgroundScan: Bool { didSet { save(backgroundScan, "backgroundScan") } }
  var scanLoad: ScanLoad { didSet { save(scanLoad.rawValue, "scanLoad") } }

  // Cleaning
  var moveToTrash: Bool { didSet { save(moveToTrash, "moveToTrash") } }
  /// Days History keeps removed items restorable.
  var keepDays: Int { didSet { save(keepDays, "keepDays") } }
  /// Files younger than this are never suggested for cleanup.
  var minimumAgeDays: Int { didSet { save(minimumAgeDays, "minimumAgeDays") } }
  var alwaysConfirm: Bool { didSet { save(alwaysConfirm, "alwaysConfirm") } }
  /// Downloads deletions skip the confirmation sheet when true.
  var skipConfirmForDownloads: Bool { didSet { save(skipConfirmForDownloads, "skipConfirmDl") } }

  // Notifications
  var lowSpaceWarning: Bool { didSet { save(lowSpaceWarning, "lowSpaceWarning") } }
  var lowSpaceThresholdGB: Int { didSet { save(lowSpaceThresholdGB, "lowSpaceThresholdGB") } }
  var monthlyReport: Bool { didSet { save(monthlyReport, "monthlyReport") } }
  var notifyLargeFiles: Bool { didSet { save(notifyLargeFiles, "notifyLargeFiles") } }
  var monthlyReminder: Bool { didSet { save(monthlyReminder, "monthlyReminder") } }

  // Exclusions
  /// Folders Sector never analyzes or suggests deleting (absolute paths).
  var exclusions: [String] { didSet { save(exclusions, "exclusions") } }

  // Onboarding
  var onboarded: Bool { didSet { save(onboarded, "onboarded") } }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    func bool(_ key: String, _ fallback: Bool) -> Bool {
      defaults.object(forKey: key) as? Bool ?? fallback
    }
    func int(_ key: String, _ fallback: Int) -> Int {
      defaults.object(forKey: key) as? Int ?? fallback
    }
    launchAtLogin = bool("launchAtLogin", false)
    showInMenuBar = bool("showInMenuBar", true)
    menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .ringAndSize
    binaryUnits = bool("binaryUnits", false)
    animationsEnabled = bool("animationsEnabled", true)
    scanScope = ScanScope(rawValue: defaults.string(forKey: "scanScope") ?? "") ?? .startupDisk
    includeExternalDrives = bool("includeExternal", false)
    includeNetworkDrives = bool("includeNetwork", false)
    includeHidden = bool("includeHidden", true)
    backgroundScan = bool("backgroundScan", true)
    scanLoad = ScanLoad(rawValue: defaults.string(forKey: "scanLoad") ?? "") ?? .balanced
    moveToTrash = bool("moveToTrash", true)
    keepDays = int("keepDays", 30)
    minimumAgeDays = int("minimumAgeDays", 90)
    alwaysConfirm = bool("alwaysConfirm", true)
    skipConfirmForDownloads = bool("skipConfirmDl", false)
    lowSpaceWarning = bool("lowSpaceWarning", true)
    lowSpaceThresholdGB = int("lowSpaceThresholdGB", 20)
    monthlyReport = bool("monthlyReport", false)
    notifyLargeFiles = bool("notifyLargeFiles", true)
    monthlyReminder = bool("monthlyReminder", false)
    exclusions = defaults.stringArray(forKey: "exclusions") ?? []
    onboarded = bool("onboarded", false)
    ByteFormat.base = binaryUnits ? 1024 : 1000
  }

  private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

  /// Whether `path` lies inside a user-excluded folder.
  func isExcluded(_ path: String) -> Bool {
    exclusions.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
  }
}
