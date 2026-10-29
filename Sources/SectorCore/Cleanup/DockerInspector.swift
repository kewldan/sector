import Foundation

/// Reads unused images and dangling volumes through the `docker` CLI.
/// Never touches the VM disk image (Docker.raw) itself.
enum DockerInspector {
  struct Image: Sendable, Equatable {
    var id: String
    var repository: String
    /// Tags of this image ID in `repository`; empty for untagged images.
    var tags: [String]
    var containers: Int
    /// Bytes only this image holds (freed when it goes).
    var size: UInt64
    /// Other repositories tagging the same ID ("repo:tag").
    var otherReferences: [String] = []

    var isDangling: Bool { repository == "<none>" || repository.isEmpty }
    /// What `docker image rm` should get: every `repo:tag`, or the ID for
    /// untagged images.
    var references: [String] {
      if isDangling || tags.isEmpty { return [id] }
      return tags.map { "\(repository):\($0)" } + otherReferences
    }
  }

  struct Volume: Sendable, Equatable {
    var name: String
    var links: Int
    var size: UInt64
  }

  struct Report: Sendable, Equatable {
    var images: [Image] = []
    var volumes: [Volume] = []

    var unusedImages: [Image] { images.filter { $0.containers == 0 && $0.size > 0 } }
    var danglingVolumes: [Volume] { volumes.filter { $0.links == 0 && $0.size > 0 } }
  }

  static let candidates = [
    "/usr/local/bin/docker",
    "/opt/homebrew/bin/docker",
    NSHomeDirectory() + "/.docker/bin/docker",
    NSHomeDirectory() + "/.orbstack/bin/docker",
    "/Applications/Docker.app/Contents/Resources/bin/docker",
    "/Applications/OrbStack.app/Contents/MacOS/xbin/docker",
  ]

  /// The report, or nil when the CLI is missing or the daemon is down.
  static func inspect(docker: String) async -> Report? {
    // A quick probe first: `system df` can hang for a long time when the
    // daemon is starting or unreachable.
    guard let info = await CommandRunner.run(docker, ["info", "--format", "{{.ServerVersion}}"], timeout: 4),
      info.succeeded,
      !String(decoding: info.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty
    else { return nil }
    guard let df = await CommandRunner.run(docker, ["system", "df", "-v", "--format", "json"], timeout: 30),
      df.succeeded
    else { return nil }
    return parseSystemDF(df.output)
  }

  /// Parses `docker system df -v --format json`: one JSON object with
  /// `Images` and `Volumes` arrays (fields are strings like "1.2GB").
  static func parseSystemDF(_ data: Data) -> Report? {
    let objects: [[String: Any]]
    if let one = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      objects = [one]
    } else {
      // Older CLIs print one object per line.
      objects = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
      }
    }
    guard !objects.isEmpty else { return nil }
    var report = Report()
    for object in objects {
      for raw in object["Images"] as? [[String: Any]] ?? [] {
        let id = string(raw["ID"])
        guard !id.isEmpty else { continue }
        let tag = string(raw["Tag"])
        let unique = raw["UniqueSize"].flatMap(bytes)
        report.images.append(
          Image(
            id: id, repository: string(raw["Repository"]),
            tags: tag.isEmpty || tag == "<none>" ? [] : [tag],
            containers: int(raw["Containers"]) ?? 0,
            size: unique ?? raw["Size"].flatMap(bytes) ?? 0))
      }
      for raw in object["Volumes"] as? [[String: Any]] ?? [] {
        let name = string(raw["Name"])
        guard !name.isEmpty else { continue }
        report.volumes.append(
          Volume(name: name, links: int(raw["Links"]) ?? 1, size: raw["Size"].flatMap(bytes) ?? 0))
      }
    }
    // The same image ID is listed once per tag; merge them so its size is
    // counted once and removal drops every tag.
    var merged: [Image] = []
    var index: [String: Int] = [:]
    for image in report.images {
      guard let i = index[image.id] else {
        index[image.id] = merged.count
        merged.append(image)
        continue
      }
      merged[i].containers = max(merged[i].containers, image.containers)
      if image.isDangling { continue }
      if merged[i].isDangling {
        let other = merged[i].otherReferences
        merged[i] = image
        merged[i].otherReferences = other
      } else if image.repository == merged[i].repository {
        merged[i].tags += image.tags
      } else {
        merged[i].otherReferences += image.references
      }
    }
    report.images = merged
    return report
  }

  /// Parses Docker's human sizes ("412MB", "1.23GB", "12.5kB", "0B").
  /// Docker uses decimal units.
  static func parseSize(_ text: String) -> UInt64? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed != "N/A" else { return nil }
    let digits = trimmed.prefix { $0.isNumber || $0 == "." }
    guard let value = Double(digits) else { return nil }
    let unit = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased()
    let scale: Double =
      switch unit {
      case "", "b": 1
      case "kb", "k": 1e3
      case "mb", "m": 1e6
      case "gb", "g": 1e9
      case "tb", "t": 1e12
      case "kib": 1024
      case "mib": 1_048_576
      case "gib": 1_073_741_824
      default: 1
      }
    return UInt64(value * scale)
  }

  private static func string(_ value: Any?) -> String {
    switch value {
    case let s as String: return s
    case let n as NSNumber: return n.stringValue
    default: return ""
    }
  }

  private static func int(_ value: Any?) -> Int? {
    switch value {
    case let n as NSNumber: return n.intValue
    case let s as String: return Int(s)
    default: return nil
    }
  }

  private static func bytes(_ value: Any) -> UInt64? {
    switch value {
    case let n as NSNumber: return n.uint64Value
    case let s as String: return parseSize(s)
    default: return nil
    }
  }
}
