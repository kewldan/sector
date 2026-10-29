import Foundation

/// How confident Smart Clean is that removing something is harmless.
public enum CleanupSafety: String, Sendable, Codable, Hashable {
  /// Regenerable or already discarded data; preselected by "Выбрать безопасное".
  case safe
  /// Possibly wanted by the user ("Проверьте"); never preselected.
  case review
}

/// One file or folder Smart Clean may remove, with the size it frees.
public struct CleanupFile: Sendable, Hashable {
  public var url: URL
  public var size: UInt64
  /// Regular files inside (1 for a file), for the "объектов" counters.
  public var fileCount: Int

  public init(url: URL, size: UInt64, fileCount: Int) {
    self.url = url
    self.size = size
    self.fileCount = fileCount
  }
}

/// A Docker object removed through the CLI.
public struct DockerObject: Sendable, Hashable {
  /// What to pass to `docker image rm` / `docker volume rm`: every tag of
  /// one image (it is freed only when all go), the image ID for untagged
  /// images, or a volume name.
  public var references: [String]
  public var size: UInt64

  public init(references: [String], size: UInt64) {
    self.references = references
    self.size = size
  }
}

/// A simulator device removed through `xcrun simctl delete`.
public struct SimulatorDevice: Sendable, Hashable {
  public var udid: String
  /// `~/Library/Developer/CoreSimulator/Devices/<udid>`.
  public var directory: URL
  public var size: UInt64
  public var fileCount: Int

  public init(udid: String, directory: URL, size: UInt64, fileCount: Int) {
    self.udid = udid
    self.directory = directory
    self.size = size
    self.fileCount = fileCount
  }
}

/// What removing an item actually does.
public enum CleanupTarget: Sendable, Hashable {
  /// Files and folders deleted (or trashed, per the category's mode).
  case files([CleanupFile])
  /// `docker image rm` for each reference.
  case dockerImages(docker: String, [DockerObject])
  /// `docker volume rm` for each name.
  case dockerVolumes(docker: String, [DockerObject])
  /// `xcrun simctl delete` for each device.
  case simulators(xcrun: String, [SimulatorDevice])

  /// Objects the target removes, for progress counters.
  public var objectCount: Int {
    switch self {
    case .files(let files): return files.reduce(0) { $0 + max(1, $1.fileCount) }
    case .dockerImages(_, let objects), .dockerVolumes(_, let objects): return objects.count
    case .simulators(_, let devices): return devices.reduce(0) { $0 + max(1, $1.fileCount) }
    }
  }
}

/// A selectable row inside a category ("DerivedData", "landing-2025").
public struct CleanupItem: Sendable, Hashable, Identifiable {
  /// Unique across categories and stable between analyses.
  public var id: String
  public var name: String
  /// Where it lives, abbreviated ("~/Library/Developer/Xcode").
  public var detail: String
  public var size: UInt64
  public var safety: CleanupSafety
  public var target: CleanupTarget

  public init(
    id: String, name: String, detail: String, size: UInt64, safety: CleanupSafety,
    target: CleanupTarget
  ) {
    self.id = id
    self.name = name
    self.detail = detail
    self.size = size
    self.safety = safety
    self.target = target
  }

  public var objectCount: Int { target.objectCount }
}

/// A group of findings shown as one card ("Кэши Xcode").
public struct CleanupCategory: Sendable, Hashable, Identifiable {
  public enum Kind: String, Sendable, CaseIterable, Codable {
    case xcode, nodeModules, docker, simulators, appCaches, trash, logs, downloads
  }

  public var kind: Kind
  public var title: String
  /// Short name for the cleaning progress list ("node_modules").
  public var shortTitle: String
  public var description: String
  /// SF Symbol name.
  public var symbol: String
  public var safety: CleanupSafety
  public var mode: RemovalMode
  /// Largest first.
  public var items: [CleanupItem]

  public var id: Kind { kind }
  public var size: UInt64 { items.reduce(0) { $0 + $1.size } }
  public var objectCount: Int { items.reduce(0) { $0 + $1.objectCount } }

  /// Items "Выбрать безопасное" turns on.
  public var safeItems: [CleanupItem] {
    safety == .safe ? items.filter { $0.safety == .safe } : []
  }

  public init(
    kind: Kind, title: String, shortTitle: String, description: String, symbol: String,
    safety: CleanupSafety, mode: RemovalMode, items: [CleanupItem]
  ) {
    self.kind = kind
    self.title = title
    self.shortTitle = shortTitle
    self.description = description
    self.symbol = symbol
    self.safety = safety
    self.mode = mode
    self.items = items.sorted { $0.size > $1.size }
  }
}
