import Foundation

/// Inputs of a Smart Clean analysis. Everything the rules depend on is
/// passed in, so the analyzer runs off the main actor and in tests.
public struct CleanupContext: Sendable {
  public var home: URL
  public var tree: FileTree?
  /// Projects and downloads younger than this are never suggested.
  public var minimumAgeDays: Int
  /// Folders never analyzed or suggested (absolute paths).
  public var exclusions: [String]
  public var now: Date
  /// Bundle IDs of running apps; their caches are left alone.
  public var runningBundleIDs: Set<String>
  /// Bundle IDs whose caches are never offered (Sector itself).
  public var excludedBundleIDs: Set<String>
  /// Resolves a bundle ID to its installed app (NSWorkspace in the app).
  public var appURL: @Sendable (String) -> URL?
  /// When an item was added to its folder (Downloads, Trash ages).
  public var addedDate: @Sendable (URL) -> Date?
  /// Whether to query `docker` and `xcrun simctl`.
  public var usesTools: Bool
  /// Overrides for the tool locations; nil looks in the usual places.
  public var dockerPath: String?
  public var xcrunPath: String?

  public init(
    home: URL = URL(fileURLWithPath: NSHomeDirectory()), tree: FileTree?,
    minimumAgeDays: Int = 90, exclusions: [String] = [], now: Date = Date(),
    runningBundleIDs: Set<String> = [], excludedBundleIDs: Set<String> = [],
    appURL: @escaping @Sendable (String) -> URL? = { _ in nil },
    addedDate: @escaping @Sendable (URL) -> Date? = { FileMetadata.addedDate($0) },
    usesTools: Bool = true, dockerPath: String? = nil, xcrunPath: String? = nil
  ) {
    self.home = home
    self.tree = tree
    self.minimumAgeDays = minimumAgeDays
    self.exclusions = exclusions
    self.now = now
    self.runningBundleIDs = runningBundleIDs
    self.excludedBundleIDs = excludedBundleIDs
    self.appURL = appURL
    self.addedDate = addedDate
    self.usesTools = usesTools
    self.dockerPath = dockerPath
    self.xcrunPath = xcrunPath
  }

  var homePath: String { home.standardizedFileURL.path }
  var ageCutoff: Date { now.addingTimeInterval(-Double(max(0, minimumAgeDays)) * 86_400) }

  /// Inside an excluded folder, or containing one (removing it would take
  /// the excluded folder along).
  func isBlocked(_ path: String) -> Bool {
    exclusions.contains { raw in
      let excluded = raw.hasSuffix("/") && raw.count > 1 ? String(raw.dropLast()) : raw
      return path == excluded || path.hasPrefix(excluded + "/") || excluded.hasPrefix(path + "/")
    }
  }

  /// "~/Library/Developer/Xcode"
  func abbreviate(_ path: String) -> String {
    let home = homePath
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
  }
}

/// Smart Clean rules: turns the disk (preferably the scanned tree) into
/// cleanup categories.
public enum CleanupAnalyzer {
  /// Display order, as in the mock.
  public static let order = CleanupCategory.Kind.allCases

  /// Every category, in display order. Runs the tool queries (Docker,
  /// simulators) concurrently with the file rules.
  public static func analyze(_ context: CleanupContext) async -> [CleanupCategory] {
    async let tools = analyzeTools(context)
    let files = await Task.detached(priority: .userInitiated) { analyzeFiles(context) }.value
    return sorted(files + (await tools))
  }

  /// Categories that only read the file system. Blocking; call off-main.
  public static func analyzeFiles(_ context: CleanupContext) -> [CleanupCategory] {
    let source = CleanupFileSource(tree: context.tree)
    let rules: [(CleanupContext, CleanupFileSource) -> CleanupCategory?] = [
      xcode, nodeModules, appCaches, trash, logs, downloads,
    ]
    return sorted(rules.compactMap { $0(context, source) })
  }

  /// Docker and simulator categories; empty when the tools are missing or
  /// the Docker daemon is not running.
  public static func analyzeTools(_ context: CleanupContext) async -> [CleanupCategory] {
    guard context.usesTools else { return [] }
    async let docker = docker(context)
    async let simulators = simulators(context, CleanupFileSource(tree: context.tree))
    return sorted([await docker, await simulators].compactMap { $0 })
  }

  public static func sorted(_ categories: [CleanupCategory]) -> [CleanupCategory] {
    categories.sorted { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
  }

  // MARK: - Helpers

  /// The unblocked children of `directory` as one item.
  static func contentsItem(
    id: String, name: String, directory: String, safety: CleanupSafety,
    context: CleanupContext, source: CleanupFileSource
  ) -> CleanupItem? {
    guard !context.isBlocked(directory) else { return nil }
    let files = source.children(directory)
      .filter { !context.isBlocked($0.path) && !isProtected($0.path) }
      .map(\.cleanupFile)
    return item(
      id: id, name: name, detail: context.abbreviate((directory as NSString).deletingLastPathComponent),
      files: files, safety: safety)
  }

  static func item(
    id: String, name: String, detail: String, files: [CleanupFile], safety: CleanupSafety
  ) -> CleanupItem? {
    let size = files.reduce(0) { $0 + $1.size }
    guard size > 0 else { return nil }
    return CleanupItem(
      id: id, name: name, detail: detail, size: size, safety: safety,
      target: .files(files.sorted { $0.size > $1.size }))
  }

  /// Paths Smart Clean never removes, whatever the rules say.
  static func isProtected(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    return name == "Docker.raw" || path.contains("/Library/Containers/com.docker.docker")
      || path.contains("/Group Containers/group.com.docker")
  }

  static func category(
    _ kind: CleanupCategory.Kind, title: String? = nil, description: String,
    items: [CleanupItem]
  ) -> CleanupCategory? {
    guard !items.isEmpty else { return nil }
    return CleanupCategory(
      kind: kind, title: title ?? kind.title, shortTitle: kind.shortTitle, description: description,
      symbol: kind.symbol, safety: kind.safety, mode: kind.mode, items: items)
  }

  // MARK: - Xcode

  static func xcode(_ context: CleanupContext, _ source: CleanupFileSource) -> CleanupCategory? {
    let xcode = context.homePath + "/Library/Developer/Xcode"
    var items: [CleanupItem] = []
    var parts: [String] = []

    if let derived = contentsItem(
      id: "xcode.derivedData", name: "DerivedData", directory: xcode + "/DerivedData",
      safety: .safe, context: context, source: source)
    {
      items.append(derived)
      parts.append("DerivedData")
    }
    let supports = source.children(xcode)
      .filter { $0.isDirectory && $0.name.hasSuffix("DeviceSupport") }
      .compactMap {
        contentsItem(
          id: "xcode.\($0.name)", name: $0.name, directory: $0.path, safety: .safe,
          context: context, source: source)
      }
    if !supports.isEmpty {
      items += supports
      parts.append("DeviceSupport")
    }
    if let archives = contentsItem(
      id: "xcode.archives", name: "Archives", directory: xcode + "/Archives", safety: .review,
      context: context, source: source)
    {
      items.append(archives)
      parts.append(String(localized: "архивы сборок"))
    }
    // Xcode keeps its cache open while running.
    if !context.runningBundleIDs.contains("com.apple.dt.Xcode"),
      let cache = contentsItem(
        id: "xcode.cache", name: String(localized: "Кэш Xcode"),
        directory: context.homePath + "/Library/Caches/com.apple.dt.Xcode", safety: .safe,
        context: context, source: source)
    {
      items.append(cache)
      parts.append(String(localized: "кэши"))
    }
    return category(.xcode, description: parts.joined(separator: ", "), items: items)
  }

  // MARK: - node_modules

  /// `node_modules` of projects under the home folder whose own files (not
  /// counting `node_modules`) were not touched for `minimumAgeDays`.
  static func nodeModules(_ context: CleanupContext, _ source: CleanupFileSource)
    -> CleanupCategory?
  {
    guard let tree = context.tree, let home = source.node(context.homePath) else { return nil }
    let cutoff = UInt32(clamping: Int(context.ageCutoff.timeIntervalSince1970))
    let nodeModules = Array("node_modules".utf8)
    let packageJSON = Array("package.json".utf8)
    let library = Array("Library".utf8)

    var found: [NodeID] = []
    var stack: [NodeID] = [home]
    while let dir = stack.popLast() {
      for child in tree.children(dir) where tree.isDirectory(child) && !tree.isRemoved(child) {
        let flags = tree.flags(child)
        if flags.contains(.package) || flags.contains(.symlink) || tree.nameIsDotted(child) {
          continue
        }
        if dir == home && tree.nameMatches(child, library) { continue }
        if tree.nameMatches(child, nodeModules) {
          if dir != home, tree.children(dir).contains(where: { tree.nameMatches($0, packageJSON) }) {
            found.append(child)
          }
          continue
        }
        stack.append(child)
      }
    }

    var items: [CleanupItem] = []
    for modules in found {
      guard let project = tree.parent(modules), tree.size(modules) > 0 else { continue }
      let path = tree.path(modules)
      guard !context.isBlocked(path) else { continue }
      guard let newest = newestModification(tree, project, skipping: nodeModules), newest < cutoff
      else { continue }
      let projectPath = tree.path(project)
      items.append(
        CleanupItem(
          id: "node.\(path)", name: tree.name(project),
          detail: context.abbreviate((projectPath as NSString).deletingLastPathComponent),
          size: tree.size(modules), safety: .safe,
          target: .files([
            CleanupFile(
              url: URL(fileURLWithPath: path, isDirectory: true), size: tree.size(modules),
              fileCount: tree.fileCount(modules))
          ])))
    }
    let description =
      Plural.format(items.count, "папка", "папки", "папок") + " · "
      + String(
        localized: "проекты не открывались больше \(Plural.format(context.minimumAgeDays, "дня", "дней", "дней"))"
      )
    return category(.nodeModules, description: description, items: items)
  }

  /// Newest mtime in a project, ignoring `node_modules` folders. Gives up
  /// (nil, treated as active) on huge trees.
  static func newestModification(_ tree: FileTree, _ root: NodeID, skipping name: [UInt8])
    -> UInt32?
  {
    var newest = tree.modificationTime(root)
    var stack: [NodeID] = [root]
    var visited = 0
    while let dir = stack.popLast() {
      for child in tree.children(dir) where !tree.isRemoved(child) {
        visited += 1
        if visited > 250_000 { return nil }
        if tree.isDirectory(child) {
          if tree.nameMatches(child, name) { continue }
          stack.append(child)
        }
        newest = max(newest, tree.modificationTime(child))
      }
    }
    return newest
  }

  // MARK: - App caches

  /// Cache folders of tools without an app bundle: name → display name and
  /// the bundle ID prefix that marks the owner as running.
  static let knownCaches: [String: (name: String, owner: String?)] = [
    "Homebrew": ("Homebrew", nil),
    "pip": ("pip", nil),
    "pypoetry": ("Poetry", nil),
    "Yarn": ("Yarn", nil),
    "pnpm": ("pnpm", nil),
    "node-gyp": ("node-gyp", nil),
    "ms-playwright": ("Playwright", nil),
    "ms-playwright-go": ("Playwright", nil),
    "go-build": ("Go", nil),
    "Cypress": ("Cypress", nil),
    "typescript": ("TypeScript", nil),
    "electron": ("Electron", nil),
    "electron-builder": ("electron-builder", nil),
    "CocoaPods": ("CocoaPods", nil),
    "org.carthage.CarthageKit": ("Carthage", nil),
    "deno": ("Deno", nil),
    "bun": ("Bun", nil),
    "ccache": ("ccache", nil),
    "JetBrains": ("JetBrains", "com.jetbrains."),
    "Google": ("Google Chrome", "com.google.Chrome"),
    "Mozilla": ("Firefox", "org.mozilla.firefox"),
    "Firefox": ("Firefox", "org.mozilla.firefox"),
    "BraveSoftware": ("Brave", "com.brave.Browser"),
    "Microsoft Edge": ("Microsoft Edge", "com.microsoft.edgemac"),
  ]

  /// Folders where an app counts as installed (not a system agent).
  static func isUserApp(_ url: URL, home: String) -> Bool {
    let path = url.path
    return path.hasPrefix("/Applications/") || path.hasPrefix("/System/Applications/")
      || path.hasPrefix(home + "/Applications/")
  }

  /// `~/Library/Caches/*` grouped by owning app. Only folders that belong to
  /// an installed app or a known tool qualify; system daemons' caches and
  /// caches of running apps are left alone.
  static func appCaches(_ context: CleanupContext, _ source: CleanupFileSource) -> CleanupCategory?
  {
    let caches = context.homePath + "/Library/Caches"
    var groups: [String: [CleanupFile]] = [:]
    for entry in source.children(caches) where entry.isDirectory && entry.size > 0 {
      let name = entry.name
      guard name != "com.apple.dt.Xcode", !context.excludedBundleIDs.contains(name),
        !context.isBlocked(entry.path), !isProtected(entry.path)
      else { continue }

      let display: String
      if let known = knownCaches[name] {
        if let owner = known.owner,
          context.runningBundleIDs.contains(where: { $0 == owner || $0.hasPrefix(owner) })
        {
          continue
        }
        display = known.name
      } else {
        guard name.contains("."), !name.contains(" "), !name.hasPrefix("@") else { continue }
        let bundleID = name.hasSuffix(".ShipIt") ? String(name.dropLast(".ShipIt".count)) : name
        guard !context.excludedBundleIDs.contains(bundleID),
          !context.runningBundleIDs.contains(bundleID),
          let app = context.appURL(bundleID), isUserApp(app, home: context.homePath)
        else { continue }
        display = appDisplayName(app)
      }
      let files = source.children(entry.path)
        .filter { !context.isBlocked($0.path) && !isProtected($0.path) }
        .map(\.cleanupFile)
      groups[display, default: []] += files
    }

    let minimum: UInt64 = 512 * 1024
    let items = groups.compactMap { name, files -> CleanupItem? in
      guard files.reduce(0, { $0 + $1.size }) >= minimum else { return nil }
      return item(
        id: "caches.\(name)", name: name, detail: context.abbreviate(caches), files: files,
        safety: .safe)
    }
    .sorted { $0.size > $1.size }

    let names = items.prefix(3).map(\.name)
    var description = ListFormatter.localizedString(byJoining: names)
    if items.count > 3 {
      description =
        names.joined(separator: ", ") + " "
        + String(
          localized: "и ещё \(Plural.format(items.count - 3, "приложение", "приложения", "приложений"))")
    }
    return category(.appCaches, description: description, items: items)
  }

  static func appDisplayName(_ url: URL) -> String {
    let name = FileManager.default.displayName(atPath: url.path)
    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
  }

  // MARK: - Trash

  static func trash(_ context: CleanupContext, _ source: CleanupFileSource) -> CleanupCategory? {
    let trash = context.homePath + "/.Trash"
    guard !context.isBlocked(trash) else { return nil }
    let entries = source.children(trash).filter { !context.isBlocked($0.path) }
    let cutoff = context.now.addingTimeInterval(-30 * 86_400)
    var old: [CleanupFile] = []
    var rest: [CleanupFile] = []
    for entry in entries {
      let added = context.addedDate(entry.url) ?? entry.modified
      if added < cutoff { old.append(entry.cleanupFile) } else { rest.append(entry.cleanupFile) }
    }
    let detail = context.abbreviate(trash)
    let items = [
      item(
        id: "trash.old", name: String(localized: "Файлы старше 30 дней"), detail: detail, files: old,
        safety: .safe),
      item(
        id: "trash.recent", name: String(localized: "Остальное"), detail: detail, files: rest,
        safety: .safe),
    ].compactMap { $0 }
    let description = Plural.format(entries.count, "объект", "объекта", "объектов")
    return category(.trash, description: description, items: items)
  }

  // MARK: - Logs

  static func logs(_ context: CleanupContext, _ source: CleanupFileSource) -> CleanupCategory? {
    let logs = context.homePath + "/Library/Logs"
    guard !context.isBlocked(logs) else { return nil }
    var items: [CleanupItem] = []
    if let reports = contentsItem(
      id: "logs.diagnostic", name: "DiagnosticReports", directory: logs + "/DiagnosticReports",
      safety: .safe, context: context, source: source)
    {
      items.append(reports)
    }
    let others = source.children(logs)
      .filter { $0.name != "DiagnosticReports" && !context.isBlocked($0.path) }
      .map(\.cleanupFile)
    if let journals = item(
      id: "logs.apps", name: String(localized: "Журналы приложений"),
      detail: context.abbreviate(logs), files: others, safety: .safe)
    {
      items.append(journals)
    }
    return category(
      .logs, description: String(localized: "Системные журналы и диагностические отчёты"),
      items: items)
  }

  // MARK: - Downloads

  static let diskImageExtensions: Set<String> = ["dmg", "iso", "img", "sparseimage", "pkg", "mpkg"]
  static let archiveExtensions: Set<String> = [
    "zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar", "zst",
  ]

  /// Top-level Downloads entries added more than `minimumAgeDays` ago.
  static func downloads(_ context: CleanupContext, _ source: CleanupFileSource) -> CleanupCategory?
  {
    let downloads = context.homePath + "/Downloads"
    guard !context.isBlocked(downloads) else { return nil }
    let cutoff = context.ageCutoff
    var images: [CleanupFile] = []
    var archives: [CleanupFile] = []
    var other: [CleanupFile] = []
    for entry in source.children(downloads) where !entry.name.hasPrefix(".") {
      guard !context.isBlocked(entry.path), !isProtected(entry.path) else { continue }
      let added = context.addedDate(entry.url) ?? entry.modified
      guard added < cutoff else { continue }
      let ext = (entry.name as NSString).pathExtension.lowercased()
      if diskImageExtensions.contains(ext) {
        images.append(entry.cleanupFile)
      } else if archiveExtensions.contains(ext) {
        archives.append(entry.cleanupFile)
      } else {
        other.append(entry.cleanupFile)
      }
    }
    let detail = context.abbreviate(downloads)
    let items = [
      item(
        id: "downloads.images", name: String(localized: "Образы дисков (.dmg)"), detail: detail,
        files: images, safety: .review),
      item(
        id: "downloads.archives", name: String(localized: "Архивы (.zip, .tar.gz)"),
        detail: detail, files: archives, safety: .review),
      item(
        id: "downloads.other", name: String(localized: "Прочее"), detail: detail, files: other,
        safety: .review),
    ].compactMap { $0 }
    let days = Plural.format(context.minimumAgeDays, "дня", "дней", "дней")
    return category(
      .downloads, title: String(localized: "Загрузки старше \(days)"),
      description: String(localized: "Установщики, архивы, образы дисков"), items: items)
  }

  // MARK: - Docker

  static func docker(_ context: CleanupContext) async -> CleanupCategory? {
    guard let docker = context.dockerPath ?? CommandRunner.locate(DockerInspector.candidates),
      let report = await DockerInspector.inspect(docker: docker)
    else { return nil }
    return dockerCategory(report, docker: docker)
  }

  static func dockerCategory(_ report: DockerInspector.Report, docker: String) -> CleanupCategory? {
    let images = report.unusedImages
    var byRepository: [String: [DockerInspector.Image]] = [:]
    for image in images {
      byRepository[image.isDangling ? "" : image.repository, default: []].append(image)
    }
    var items: [CleanupItem] = byRepository.map { repository, images in
      let name: String
      if repository.isEmpty {
        name = String(localized: "Образы без тега") + (images.count > 1 ? " ×\(images.count)" : "")
      } else if images.count == 1, let tag = images[0].tags.first {
        name = "\(repository):\(tag)"
      } else {
        name = "\(repository) ×\(images.count)"
      }
      let objects = images.map { DockerObject(references: $0.references, size: $0.size) }
      return CleanupItem(
        id: "docker.image.\(repository.isEmpty ? "<none>" : repository)", name: name,
        detail: "docker images", size: objects.reduce(0) { $0 + $1.size }, safety: .safe,
        target: .dockerImages(docker: docker, objects))
    }
    let volumes = report.danglingVolumes
    if !volumes.isEmpty {
      let objects = volumes.map { DockerObject(references: [$0.name], size: $0.size) }
      // Volumes hold data (databases), not rebuildable layers.
      items.append(
        CleanupItem(
          id: "docker.volumes", name: String(localized: "Тома без контейнеров"),
          detail: "docker volumes", size: objects.reduce(0) { $0 + $1.size }, safety: .review,
          target: .dockerVolumes(docker: docker, objects)))
    }
    var description = Plural.format(images.count, "образ", "образа", "образов")
    if !volumes.isEmpty {
      description +=
        ", "
        + String(localized: "\(Plural.format(volumes.count, "том", "тома", "томов")) без владельца")
    }
    return category(.docker, description: description, items: items)
  }

  // MARK: - Simulators

  static func simulators(_ context: CleanupContext, _ source: CleanupFileSource) async
    -> CleanupCategory?
  {
    let xcrun = context.xcrunPath ?? SimulatorInspector.xcrun
    guard let devices = await SimulatorInspector.devices(xcrun: xcrun) else { return nil }
    let removable = SimulatorInspector.removable(devices, bootedBefore: context.ageCutoff)
    return await Task.detached(priority: .userInitiated) {
      simulatorCategory(removable, xcrun: xcrun, context: context, source: source)
    }.value
  }

  static func simulatorCategory(
    _ devices: [SimulatorInspector.Device], xcrun: String, context: CleanupContext,
    source: CleanupFileSource
  ) -> CleanupCategory? {
    let devicesRoot = context.homePath + "/Library/Developer/CoreSimulator/Devices"
    var items: [CleanupItem] = []
    var runtimes: Set<SimulatorInspector.Runtime> = []
    for device in devices {
      var directory = devicesRoot + "/" + device.udid
      if let data = device.dataPath, (data as NSString).lastPathComponent == "data" {
        directory = (data as NSString).deletingLastPathComponent
      }
      guard !context.isBlocked(directory), let facts = source.facts(directory), facts.size > 0
      else { continue }
      runtimes.insert(device.runtime)
      let target = SimulatorDevice(
        udid: device.udid, directory: URL(fileURLWithPath: directory, isDirectory: true),
        size: facts.size, fileCount: facts.fileCount)
      items.append(
        CleanupItem(
          id: "sim.\(device.udid)", name: "\(device.name) · \(device.runtime.displayName)",
          detail: "CoreSimulator", size: facts.size, safety: .safe,
          target: .simulators(xcrun: xcrun, [target])))
    }
    // "iOS 17 и 18, watchOS 10 · 6 устройств"
    let platforms = Dictionary(grouping: runtimes, by: \.platform)
      .sorted { $0.key < $1.key }
      .map { platform, list in
        let majors = Set(list.map(\.major)).sorted().map(String.init)
        return "\(platform) " + (ListFormatter.localizedString(byJoining: majors))
      }
    let description =
      platforms.joined(separator: ", ") + " · "
      + Plural.format(items.count, "устройство", "устройства", "устройств")
    return category(.simulators, description: description, items: items)
  }
}

extension CleanupCategory.Kind {
  public var title: String {
    switch self {
    case .xcode: String(localized: "Кэши Xcode")
    case .nodeModules: String(localized: "node_modules в неактивных проектах")
    case .docker: String(localized: "Образы Docker без контейнеров")
    case .simulators: String(localized: "Старые симуляторы iOS")
    case .appCaches: String(localized: "Кэши приложений")
    case .trash: String(localized: "Корзина")
    case .logs: String(localized: "Логи и отчёты о сбоях")
    case .downloads: String(localized: "Загрузки старше 90 дней")
    }
  }

  public var shortTitle: String {
    switch self {
    case .xcode: String(localized: "Кэши Xcode")
    case .nodeModules: "node_modules"
    case .docker: String(localized: "Образы Docker")
    case .simulators: String(localized: "Симуляторы iOS")
    case .appCaches: String(localized: "Кэши приложений")
    case .trash: String(localized: "Корзина")
    case .logs: String(localized: "Логи и отчёты")
    case .downloads: String(localized: "Загрузки")
    }
  }

  public var symbol: String {
    switch self {
    case .xcode: "hammer"
    case .nodeModules: "cube"
    case .docker: "shippingbox"
    case .simulators: "iphone"
    case .appCaches: "cylinder.split.1x2"
    case .trash: "trash"
    case .logs: "doc.text"
    case .downloads: "arrow.down.to.line"
    }
  }

  public var safety: CleanupSafety { self == .downloads ? .review : .safe }

  /// Regenerable data is deleted outright; downloads go to the Trash so
  /// History can restore them; the Trash itself is emptied.
  public var mode: RemovalMode { self == .downloads ? .trash : .permanent }
}
