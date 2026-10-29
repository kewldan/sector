import Foundation

/// Coarse buckets the overview donut splits the disk into.
public enum DiskCategory: String, CaseIterable, Sendable, Codable, Identifiable {
  case development, media, apps, system, documents, caches, icloud, trash

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .development: return String(localized: "Разработка")
    case .media: return String(localized: "Фото и видео")
    case .apps: return String(localized: "Приложения")
    case .system: return String(localized: "Системные")
    case .documents: return String(localized: "Документы")
    case .caches: return String(localized: "Кэши и логи")
    case .icloud: return String(localized: "iCloud Drive")
    case .trash: return String(localized: "Корзина")
    }
  }

  /// Hex from the design system's disk category palette.
  public var hex: UInt32 {
    switch self {
    case .development: return 0x5E5CE6
    case .media: return 0xFF2D55
    case .apps: return 0x007AFF
    case .system: return 0x8E8E93
    case .documents: return 0xFF9500
    case .caches: return 0x34C759
    case .icloud: return 0x30B0C7
    case .trash: return 0xA2845E
    }
  }

  public var symbol: String {
    switch self {
    case .development: return "hammer"
    case .media: return "photo.on.rectangle"
    case .apps: return "square.grid.2x2"
    case .system: return "gearshape"
    case .documents: return "doc"
    case .caches: return "archivebox"
    case .icloud: return "icloud"
    case .trash: return "trash"
    }
  }
}

/// Per-category totals for a scanned tree.
public struct CategoryBreakdown: Sendable {
  public var sizes: [DiskCategory: UInt64]
  /// Category of every node, indexed by `NodeID`; lets views tint items.
  public var nodeCategories: [UInt8]

  public func category(of id: NodeID) -> DiskCategory {
    let raw = Int(nodeCategories[Int(id)])
    return DiskCategory.allCases.indices.contains(raw) ? DiskCategory.allCases[raw] : .documents
  }

  /// Categories largest first, skipping empty ones.
  public var ordered: [(category: DiskCategory, size: UInt64)] {
    DiskCategory.allCases.compactMap { c in
      let s = sizes[c] ?? 0
      return s > 0 ? (c, s) : nil
    }.sorted { $0.size > $1.size }
  }

  /// Classifies every node in one pass: a few anchor paths set a category,
  /// project folders (with `.git` or `node_modules`) count as development,
  /// loose media files outside special folders count as media, and the rest
  /// inherits from the parent. `unscanned` is space the volume reports as
  /// used but the scan could not see (snapshots, other APFS volumes,
  /// protected folders); it is added to "system".
  public static func compute(
    tree: FileTree, home: String = NSHomeDirectory(), unscanned: UInt64 = 0
  ) -> CategoryBreakdown {
    let count = tree.count
    var anchors: [NodeID: DiskCategory] = [:]
    func anchor(_ path: String, _ category: DiskCategory) {
      if let id = tree.find(path: path) { anchors[id] = category }
    }

    let systemRoots = ["/System", "/Library", "/usr", "/private", "/bin", "/sbin", "/opt", "/cores"]
    for p in systemRoots { anchor(p, .system) }
    anchor("/Applications", .apps)
    anchor(home + "/Applications", .apps)
    anchor(home + "/Library", .system)
    anchor(home + "/Library/Application Support", .apps)
    anchor(home + "/Library/Containers", .apps)
    anchor(home + "/Library/Group Containers", .apps)
    anchor(home + "/Library/Caches", .caches)
    anchor(home + "/Library/Logs", .caches)
    anchor("/Library/Caches", .caches)
    anchor("/Library/Logs", .caches)
    anchor("/private/var/folders", .caches)
    anchor("/private/var/log", .caches)
    anchor(home + "/Library/Mobile Documents", .icloud)
    anchor(home + "/.Trash", .trash)
    for p in ["/Pictures", "/Movies", "/Music"] { anchor(home + p, .media) }
    for p in [
      "/Library/Developer", "/Developer", "/.npm", "/.gradle", "/.cargo", "/.rustup", "/.m2",
      "/go", "/.docker", "/.orbstack", "/Library/Containers/com.docker.docker", "/.cache",
      "/.bun", "/.pyenv", "/.conda", "/miniconda3", "/anaconda3", "/.android", "/Library/Android",
      "/.pub-cache", "/.nuget", "/.vscode", "/.cocoapods",
    ] {
      anchor(home + p, .development)
    }
    // Group-container data of OrbStack/Docker Desktop hides VM disk images.
    if let groups = tree.find(path: home + "/Library/Group Containers") {
      for child in tree.children(groups) where tree.name(child).contains("orbstack") {
        anchors[child] = .development
      }
    }

    let homeID = tree.find(path: home)
    let gitBytes = Array(".git".utf8)
    let modulesBytes = Array("node_modules".utf8)
    let casesIndex = Dictionary(
      uniqueKeysWithValues: DiskCategory.allCases.enumerated().map { ($1, UInt8($0)) })
    let devRaw = casesIndex[.development]!
    let docRaw = casesIndex[.documents]!
    let mediaRaw = casesIndex[.media]!

    var cats = [UInt8](repeating: docRaw, count: count)
    cats[0] = tree.rootPath == "/" ? casesIndex[.system]! : docRaw
    if let homeID { anchors[homeID] = anchors[homeID] ?? .documents }

    for i in 1..<count {
      let id = NodeID(i)
      let parent = Int(tree.parents[i])
      if let a = anchors[id] {
        cats[i] = casesIndex[a]!
        continue
      }
      var c = cats[parent]
      if c == docRaw && tree.isDirectory(id) && hasMarkerChild(tree, id, gitBytes, modulesBytes) {
        c = devRaw
      } else if c == docRaw && !tree.isDirectory(id) && isMedia(tree, id) {
        c = mediaRaw
      }
      cats[i] = c
    }

    var sizes: [DiskCategory: UInt64] = [:]
    for i in 1..<count where !tree.isDirectory(NodeID(i)) && !tree.isRemoved(NodeID(i)) {
      sizes[DiskCategory.allCases[Int(cats[i])], default: 0] &+= tree.sizes[i]
    }
    sizes[.system, default: 0] &+= unscanned
    return CategoryBreakdown(sizes: sizes, nodeCategories: cats)
  }

  private static func hasMarkerChild(
    _ tree: FileTree, _ id: NodeID, _ git: [UInt8], _ modules: [UInt8]
  ) -> Bool {
    for child in tree.children(id) {
      let length = Int(tree.nameLengths[Int(child)])
      guard length == git.count || length == modules.count else { continue }
      let name = tree.name(child)
      if name == ".git" || name == "node_modules" { return true }
    }
    return false
  }

  private static let mediaExtensions: Set<String> = [
    "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "raw", "cr2", "cr3", "nef", "arw",
    "dng", "raf", "orf", "webp", "mov", "mp4", "m4v", "avi", "mkv", "webm", "mts", "braw", "r3d",
    "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus",
  ]

  private static func isMedia(_ tree: FileTree, _ id: NodeID) -> Bool {
    // Fast reject: media extensions are 3–4 characters after a dot.
    guard tree.nameLengths[Int(id)] >= 4 else { return false }
    return mediaExtensions.contains(tree.pathExtension(id))
  }
}
