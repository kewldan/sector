import Foundation

/// Finds removable simulator devices through `xcrun simctl`.
enum SimulatorInspector {
  struct Device: Sendable, Equatable {
    var udid: String
    var name: String
    var state: String
    var isAvailable: Bool
    var lastBooted: Date?
    var dataPath: String?
    var runtime: Runtime
  }

  /// "com.apple.CoreSimulator.SimRuntime.iOS-17-5" → iOS 17.5.
  struct Runtime: Sendable, Hashable, Comparable {
    var platform: String
    var version: [Int]

    init?(identifier: String) {
      guard let last = identifier.split(separator: ".").last else { return nil }
      let parts = last.split(separator: "-")
      guard let platform = parts.first, parts.count >= 2 else { return nil }
      let version = parts.dropFirst().compactMap { Int($0) }
      guard !version.isEmpty else { return nil }
      self.platform = platform == "xrOS" ? "visionOS" : String(platform)
      self.version = version
    }

    var major: Int { version.first ?? 0 }
    /// "iOS 17.5"
    var displayName: String {
      "\(platform) " + version.map(String.init).joined(separator: ".")
    }

    static func < (a: Runtime, b: Runtime) -> Bool {
      a.version.lexicographicallyPrecedes(b.version)
    }
  }

  static let xcrun = "/usr/bin/xcrun"

  /// All devices, or nil when simctl is unavailable (no Xcode).
  static func devices(xcrun: String = xcrun) async -> [Device]? {
    guard let result = await CommandRunner.run(xcrun, ["simctl", "list", "devices", "-j"], timeout: 15),
      result.succeeded
    else { return nil }
    return parse(result.output)
  }

  static func parse(_ data: Data) -> [Device]? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let byRuntime = root["devices"] as? [String: Any]
    else { return nil }
    let iso = ISO8601DateFormatter()
    let isoFractional = ISO8601DateFormatter()
    isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var result: [Device] = []
    for (identifier, list) in byRuntime {
      guard let runtime = Runtime(identifier: identifier), let list = list as? [[String: Any]] else {
        continue
      }
      for raw in list {
        guard let udid = raw["udid"] as? String else { continue }
        let booted = (raw["lastBootedAt"] as? String).flatMap {
          iso.date(from: $0) ?? isoFractional.date(from: $0)
        }
        result.append(
          Device(
            udid: udid, name: raw["name"] as? String ?? udid,
            state: raw["state"] as? String ?? "",
            isAvailable: raw["isAvailable"] as? Bool ?? true, lastBooted: booted,
            dataPath: raw["dataPath"] as? String, runtime: runtime))
      }
    }
    return result
  }

  /// Devices worth removing: unavailable ones (their runtime is gone), and
  /// shut-down devices on an older major OS than the newest installed for
  /// their platform that were not booted within `cutoff`.
  static func removable(_ devices: [Device], bootedBefore cutoff: Date) -> [Device] {
    var newest: [String: Int] = [:]
    for d in devices where d.isAvailable {
      newest[d.runtime.platform] = max(newest[d.runtime.platform] ?? 0, d.runtime.major)
    }
    return devices.filter { d in
      guard d.state == "Shutdown" else { return false }
      if !d.isAvailable { return true }
      guard let latest = newest[d.runtime.platform], d.runtime.major < latest else { return false }
      return (d.lastBooted ?? .distantPast) < cutoff
    }
  }
}
