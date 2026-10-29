import Darwin
import Foundation
import Security
import Synchronization

/// Data an app keeps outside its bundle, removed together with it.
public struct AppRelatedItem: Sendable, Hashable, Identifiable {
  public enum Kind: String, Sendable, CaseIterable {
    case applicationSupport, caches, containers, groupContainers, preferences, savedState
    case logs, httpStorages, webKit, cookies, launchAgents, applicationScripts

    /// Folder name inside `~/Library`, also the row title (Finder shows
    /// these names untranslated).
    public var folder: String {
      switch self {
      case .applicationSupport: return "Application Support"
      case .caches: return "Caches"
      case .containers: return "Containers"
      case .groupContainers: return "Group Containers"
      case .preferences: return "Preferences"
      case .savedState: return "Saved Application State"
      case .logs: return "Logs"
      case .httpStorages: return "HTTPStorages"
      case .webKit: return "WebKit"
      case .cookies: return "Cookies"
      case .launchAgents: return "LaunchAgents"
      case .applicationScripts: return "Application Scripts"
      }
    }
  }

  public var id: String { url.path }
  public var kind: Kind
  public var url: URL
  public var size: UInt64

  public init(kind: Kind, url: URL, size: UInt64) {
    self.kind = kind
    self.url = url
    self.size = size
  }
}

/// An installed application bundle.
public struct InstalledApp: Sendable, Hashable, Identifiable {
  public var id: String { url.path }
  public var url: URL
  public var name: String
  public var bundleID: String?
  public var version: String?
  /// Developer, from the signing certificate or the copyright line.
  public var vendor: String?
  public var size: UInt64
  public var lastUsed: Date?
  public var related: [AppRelatedItem]

  public init(
    url: URL, name: String, bundleID: String?, version: String?, vendor: String?, size: UInt64,
    lastUsed: Date?, related: [AppRelatedItem]
  ) {
    self.url = url
    self.name = name
    self.bundleID = bundleID
    self.version = version
    self.vendor = vendor
    self.size = size
    self.lastUsed = lastUsed
    self.related = related
  }

  public var relatedSize: UInt64 { related.reduce(0) { $0 + $1.size } }
  public var totalSize: UInt64 { size + relatedSize }
}

/// Finds removable `.app` bundles and the data they leave in `~/Library`.
public struct AppInventory: Sendable {
  /// Size of a path from an existing scan, or nil to measure it.
  public typealias SizeLookup = @Sendable (String) -> UInt64?

  public var searchRoots: [URL]
  public var libraryRoot: URL

  public static var defaultRoots: [URL] {
    [
      URL(fileURLWithPath: "/Applications"),
      URL(fileURLWithPath: NSHomeDirectory() + "/Applications"),
    ]
  }

  public init(
    searchRoots: [URL] = AppInventory.defaultRoots,
    libraryRoot: URL = URL(fileURLWithPath: NSHomeDirectory() + "/Library")
  ) {
    self.searchRoots = searchRoots
    self.libraryRoot = libraryRoot
  }

  /// Every removable app with its related data. Blocking; call off-main.
  public func apps(sizeOf lookup: SizeLookup? = nil) -> [InstalledApp] {
    let bundles = bundleURLs()
    let results = Mutex([InstalledApp?](repeating: nil, count: bundles.count))
    DispatchQueue.concurrentPerform(iterations: bundles.count) { i in
      let app = self.app(at: bundles[i], sizeOf: lookup)
      results.withLock { $0[i] = app }
    }
    return results.withLock { $0 }.compactMap { $0 }
  }

  /// `.app` bundles in the search roots and one folder level below them.
  public func bundleURLs() -> [URL] {
    let fm = FileManager.default
    var seen = Set<String>()
    var result: [URL] = []
    func visit(_ dir: URL, depth: Int) {
      guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
      for name in names.sorted() where !name.hasPrefix(".") {
        let url = dir.appendingPathComponent(name)
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
        if name.lowercased().hasSuffix(".app") {
          if Self.isRemovable(url, flags: st.st_flags), seen.insert(url.path).inserted {
            result.append(url)
          }
        } else if depth == 0, !Self.isPackageName(name) {
          visit(url, depth: 1)
        }
      }
    }
    for root in searchRoots { visit(root.standardizedFileURL, depth: 0) }
    return result
  }

  /// Builds an `InstalledApp` for a bundle.
  public func app(at url: URL, sizeOf lookup: SizeLookup? = nil) -> InstalledApp? {
    let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
    let bundleID = info?["CFBundleIdentifier"] as? String
    let fileName = url.deletingPathExtension().lastPathComponent
    let bundleName = (info?["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let version =
      (info?["CFBundleShortVersionString"] as? String) ?? (info?["CFBundleVersion"] as? String)
    let signing = Self.signingInfo(url)
    let vendor =
      signing.vendor
      ?? Self.vendor(fromCopyright: info?["NSHumanReadableCopyright"] as? String)
      ?? (bundleID?.hasPrefix("com.apple.") == true ? "Apple" : nil)
    let names = [fileName, bundleName].compactMap { $0 }
    let related = relatedItems(
      bundleID: bundleID, names: names, teamID: signing.teamID, sizeOf: lookup)
    return InstalledApp(
      url: url, name: fileName, bundleID: bundleID,
      version: version.flatMap { $0.isEmpty ? nil : $0 }, vendor: vendor,
      size: Self.size(of: url, lookup: lookup), lastUsed: FileMetadata.lastUsedDate(url),
      related: related)
  }

  /// Data in the Library root that clearly belongs to the app.
  public func relatedItems(
    bundleID: String?, names: [String], teamID: String? = nil, sizeOf lookup: SizeLookup? = nil
  ) -> [AppRelatedItem] {
    let fm = FileManager.default
    let lib = libraryRoot.standardizedFileURL
    var found: [(AppRelatedItem.Kind, URL)] = []
    func add(_ kind: AppRelatedItem.Kind, _ name: String) {
      let url = lib.appendingPathComponent(kind.folder).appendingPathComponent(name)
      var st = stat()
      if lstat(url.path, &st) == 0 { found.append((kind, url)) }
    }
    func list(_ kind: AppRelatedItem.Kind) -> [String] {
      (try? fm.contentsOfDirectory(atPath: lib.appendingPathComponent(kind.folder).path)) ?? []
    }

    let safeNames = Set(names.filter(Self.isDistinctiveName))
    if let id = bundleID, !id.isEmpty {
      add(.applicationSupport, id)
      add(.caches, id)
      add(.containers, id)
      add(.preferences, id + ".plist")
      add(.savedState, id + ".savedState")
      add(.logs, id)
      add(.httpStorages, id)
      add(.httpStorages, id + ".binarycookies")
      add(.webKit, id)
      add(.cookies, id + ".binarycookies")
      add(.applicationScripts, id)
      for name in list(.groupContainers)
      where Self.groupContainer(name, matches: id, teamID: teamID) {
        add(.groupContainers, name)
      }
      for name in list(.launchAgents)
      where name.hasSuffix(".plist") && (name == id + ".plist" || name.hasPrefix(id + ".")) {
        add(.launchAgents, name)
      }
      let byHost = lib.appendingPathComponent("Preferences/ByHost")
      for name in (try? fm.contentsOfDirectory(atPath: byHost.path)) ?? []
      where name.hasPrefix(id + ".") && name.hasSuffix(".plist") {
        found.append((.preferences, byHost.appendingPathComponent(name)))
      }
    }
    for name in safeNames.sorted() {
      add(.applicationSupport, name)
      add(.caches, name)
      add(.logs, name)
    }

    // Case-insensitive volumes resolve "Caches/Foo" and "Caches/foo" alike.
    var seen = Set<String>()
    var items: [AppRelatedItem] = []
    for (kind, url) in found {
      let key = (url.resolvingSymlinksInPath().path as NSString).standardizingPath.lowercased()
      guard seen.insert(key).inserted else { continue }
      items.append(AppRelatedItem(kind: kind, url: url, size: Self.size(of: url, lookup: lookup)))
    }
    return items
  }

  // MARK: - Rules

  /// Whether a Group Containers entry belongs to the app: `group.<id>…`,
  /// `<anything>.<id>`, or `<team>.<prefix of id>` with a specific prefix.
  static func groupContainer(_ name: String, matches id: String, teamID: String?) -> Bool {
    if name == "group." + id || name.hasPrefix("group." + id + ".") { return true }
    if name.hasSuffix("." + id) { return true }
    if let team = teamID, !team.isEmpty, name.hasPrefix(team + ".") {
      let rest = String(name.dropFirst(team.count + 1))
      if rest == id || rest.hasPrefix(id + ".") { return true }
      // "<team>.com.vendor.product" for "com.vendor.product.mac".
      if rest.split(separator: ".").count >= 3, id.hasPrefix(rest + ".") { return true }
    }
    return false
  }

  /// App names specific enough to match a folder by name alone.
  static func isDistinctiveName(_ name: String) -> Bool {
    let generic: Set<String> = [
      "apple", "google", "microsoft", "adobe", "app", "application", "applications", "data",
      "cache", "caches", "logs", "default", "helper", "launcher", "installer", "uninstaller",
      "update", "updater", "crashreporter", "com.apple",
    ]
    return name.count >= 3 && !generic.contains(name.lowercased())
  }

  static func isPackageName(_ name: String) -> Bool {
    let ext = (name as NSString).pathExtension.lowercased()
    return ["app", "bundle", "framework", "plugin", "kext", "pkg", "mpkg"].contains(ext)
  }

  /// Excludes bundles macOS protects: the sealed system volume, SIP
  /// (`restricted`) and read-only mounts.
  static func isRemovable(_ url: URL, flags: UInt32) -> Bool {
    if flags & UInt32(SF_RESTRICTED) != 0 { return false }
    let real = url.resolvingSymlinksInPath().path
    if real.hasPrefix("/System/") { return false }
    var fs = statfs()
    if statfs(url.path, &fs) == 0, fs.f_flags & UInt32(MNT_RDONLY) != 0 { return false }
    return true
  }

  /// "© 2024 Google LLC. All rights reserved." → "Google LLC".
  static func vendor(fromCopyright copyright: String?) -> String? {
    guard var s = copyright?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
      return nil
    }
    for token in ["Copyright", "copyright", "©", "(c)", "(C)"] {
      s = s.replacingOccurrences(of: token, with: " ")
    }
    if let range = s.range(of: #"[0-9]{4}(\s*[-–,]\s*[0-9]{4})*"#, options: .regularExpression) {
      s.removeSubrange(range)
    }
    let junk = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
    s = s.trimmingCharacters(in: junk)
    let cut = s.firstIndex { ".;\n".contains($0) } ?? s.endIndex
    s = String(s[..<cut])
    if let comma = s.range(of: ", ") { s = String(s[..<comma.lowerBound]) }
    s = s.trimmingCharacters(in: junk)
    let lowered = s.lowercased()
    guard s.count >= 2, s.count <= 40, !lowered.contains("rights"), !lowered.hasPrefix("by ")
    else { return nil }
    return s
  }

  /// Team identifier and developer name from the code signature.
  static func signingInfo(_ url: URL) -> (teamID: String?, vendor: String?) {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
      return (nil, nil)
    }
    var info: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
      let dict = info as? [String: Any]
    else { return (nil, nil) }
    let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
    var developer: String?
    if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
      let leaf = certs.first,
      let summary = SecCertificateCopySubjectSummary(leaf) as String?
    {
      developer = vendor(fromCertificate: summary)
    }
    return (team, developer)
  }

  /// "Developer ID Application: Google LLC (EQHXZ8M8AV)" → "Google LLC";
  /// Apple's own "Software Signing" → "Apple".
  static func vendor(fromCertificate summary: String) -> String? {
    if summary == "Software Signing" || summary.hasPrefix("Apple Mac OS Application Signing") {
      return summary == "Software Signing" ? "Apple" : nil
    }
    guard let colon = summary.range(of: ": ") else { return nil }
    var name = String(summary[colon.upperBound...])
    if let paren = name.range(of: " (", options: .backwards) {
      name = String(name[..<paren.lowerBound])
    }
    name = name.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : name
  }

  // MARK: - Sizes

  static func size(of url: URL, lookup: SizeLookup?) -> UInt64 {
    if let size = lookup?(url.path) { return size }
    return allocatedSize(of: url)
  }

  /// Allocated bytes of a file or folder, measured from disk.
  public static func allocatedSize(of url: URL) -> UInt64 {
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return 0 }
    guard st.st_mode & S_IFMT == S_IFDIR else { return UInt64(max(0, st.st_blocks)) * 512 }
    let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: Array(keys), options: [],
        errorHandler: { _, _ in true })
    else { return 0 }
    var total: UInt64 = 0
    for case let file as URL in enumerator {
      guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true
      else { continue }
      total += UInt64(values.totalFileAllocatedSize ?? 0)
    }
    return total
  }
}
