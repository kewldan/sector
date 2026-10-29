import Foundation

/// Capacity and identity of a mounted volume.
public struct VolumeInfo: Sendable, Identifiable, Hashable {
  public var id: URL { url }
  public var url: URL
  public var name: String
  public var fileSystem: String
  public var total: UInt64
  /// Free space as Finder reports it: includes purgeable space macOS frees
  /// on demand.
  public var available: UInt64
  public var isInternal: Bool
  public var isRemovable: Bool
  public var isNetwork: Bool

  public var used: UInt64 { total > available ? total - available : 0 }
  public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }

  /// The startup volume ("Macintosh HD"); its data lives in the APFS data
  /// volume, but "/" reports the shared container's capacity.
  public static func startup() -> VolumeInfo? { load(URL(fileURLWithPath: "/")) }

  public static func load(_ url: URL) -> VolumeInfo? {
    let keys: Set<URLResourceKey> = [
      .volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
      .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeTypeNameKey,
    ]
    guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
    let important = v.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
    let plain = v.volumeAvailableCapacity.map { UInt64(max(0, $0)) }
    return VolumeInfo(
      url: url,
      name: v.volumeName ?? url.lastPathComponent,
      fileSystem: (v.volumeTypeName ?? v.volumeLocalizedFormatDescription ?? "").uppercased(),
      total: UInt64(max(0, v.volumeTotalCapacity ?? 0)),
      available: max(important ?? 0, plain ?? 0),
      isInternal: v.volumeIsInternal ?? false,
      isRemovable: v.volumeIsRemovable ?? false,
      isNetwork: !(v.volumeIsLocal ?? true))
  }

  /// User-visible mounted volumes, startup volume first.
  public static func mounted() -> [VolumeInfo] {
    let urls =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
    var result = urls.compactMap(load)
    result.removeAll { $0.total == 0 }
    result.sort { ($0.url.path == "/" ? 0 : 1, $0.name) < ($1.url.path == "/" ? 0 : 1, $1.name) }
    return result
  }
}
