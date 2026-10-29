import Foundation

/// What the desktop widgets show, written by the app into the shared App
/// Group container and read by the sandboxed widget extension.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
  public struct Category: Codable, Sendable, Equatable, Identifiable {
    public var id: String { kind }
    /// `CleanupCategory.Kind` raw value; picks the bar color.
    public var kind: String
    /// Short label under the bar ("Xcode", "Кэши").
    public var title: String
    public var bytes: UInt64

    public init(kind: String, title: String, bytes: UInt64) {
      self.kind = kind
      self.title = title
      self.bytes = bytes
    }
  }

  public var date: Date
  public var volumeName: String
  public var total: UInt64
  public var available: UInt64
  /// Smart Clean total that can be freed safely.
  public var reclaimable: UInt64
  /// Reclaimable bytes per cleanup category, largest first.
  public var categories: [Category]

  public init(
    date: Date = Date(), volumeName: String, total: UInt64, available: UInt64,
    reclaimable: UInt64, categories: [Category]
  ) {
    self.date = date
    self.volumeName = volumeName
    self.total = total
    self.available = available
    self.reclaimable = reclaimable
    self.categories = categories
  }

  public var usedFraction: Double {
    total == 0 ? 0 : Double(total - min(available, total)) / Double(total)
  }

  /// Placeholder for widget galleries and the first run.
  public static let preview = WidgetSnapshot(
    volumeName: "Macintosh HD", total: 994_700_000_000, available: 123_400_000_000,
    reclaimable: 64_800_000_000,
    categories: [
      .init(kind: "xcode", title: "Xcode", bytes: 23_400_000_000),
      .init(kind: "nodeModules", title: "node", bytes: 12_100_000_000),
      .init(kind: "docker", title: "Docker", bytes: 9_800_000_000),
      .init(kind: "simulators", title: "Sim", bytes: 8_400_000_000),
      .init(kind: "appCaches", title: "Caches", bytes: 6_200_000_000),
      .init(kind: "trash", title: "Trash", bytes: 4_200_000_000),
      .init(kind: "logs", title: "Logs", bytes: 700_000_000),
    ])

  // MARK: - Shared container

  /// Info.plist key holding the App Group identifier, expanded from
  /// `$(TeamIdentifierPrefix)com.kewldan.sector` at build time.
  public static let groupInfoKey = "SectorAppGroup"

  /// The App Group identifier, or nil when the build was not signed with a
  /// team (the placeholder stays unexpanded).
  public static var groupIdentifier: String? {
    guard let id = Bundle.main.object(forInfoDictionaryKey: groupInfoKey) as? String,
      !id.isEmpty, !id.contains("$("), id.contains(".")
    else { return nil }
    return id
  }

  public static var fileURL: URL? {
    guard let group = groupIdentifier,
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: group)
    else { return nil }
    return container.appendingPathComponent("widget-snapshot.json")
  }

  public static func load(from url: URL? = fileURL) -> WidgetSnapshot? {
    guard let url, let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(WidgetSnapshot.self, from: data)
  }

  /// Writes the snapshot; false when there is no shared container.
  @discardableResult
  public func save(to url: URL? = fileURL) -> Bool {
    guard let url else { return false }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(self) else { return false }
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return (try? data.write(to: url, options: .atomic)) != nil
  }
}
