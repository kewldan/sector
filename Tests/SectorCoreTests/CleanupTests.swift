import Foundation
import Testing

@testable import SectorCore

/// A fake home folder with something for every file-based Smart Clean rule,
/// plus an `outside` folder next to it that must never be touched.
private struct CleanupFixture {
  let root: URL
  var home: URL { root.appendingPathComponent("home") }
  var outside: URL { root.appendingPathComponent("outside") }
  let now = Date()

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("sector-clean-\(UUID().uuidString)")
    let old = now.addingTimeInterval(-200 * 86_400)

    try write("Library/Developer/Xcode/DerivedData/App-abc/Build/x.o", 50_000)
    try write("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A)/Symbols/lib", 30_000)
    try write("Library/Developer/Xcode/Archives/2024-01-01/App.xcarchive/Info.plist", 10_000)
    try write("Library/Caches/com.example.app/cache.db", 600_000)
    try write("Library/Caches/com.example.running/data", 600_000)
    try write("Library/Caches/com.apple.someDaemon/data", 600_000)
    try write("Library/Caches/Homebrew/downloads/x.tar.gz", 600_000)
    try write("Library/Logs/DiagnosticReports/a.ips", 10_000)
    try write("Library/Logs/App/log.txt", 10_000)
    try write("Projects/old/package.json", 100)
    try write("Projects/old/index.js", 100)
    try write("Projects/old/node_modules/lib/index.js", 40_000)
    try write("Projects/old/node_modules/lib/node_modules/dep/index.js", 20_000)
    try write("Projects/fresh/package.json", 100)
    try write("Projects/fresh/node_modules/x/index.js", 40_000)
    try write("Projects/nopkg/node_modules/x/index.js", 40_000)
    try write(".Trash/old-photo.jpg", 20_000)
    try write(".Trash/new-doc.txt", 5_000)
    try write("Downloads/old-installer.dmg", 70_000)
    try write("Downloads/old-sources.zip", 30_000)
    try write("Downloads/old-notes.txt", 5_000)
    try write("Downloads/new-installer.dmg", 70_000)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data(count: 1_000).write(to: outside.appendingPathComponent("keep.txt"))
    try FileManager.default.createSymbolicLink(
      at: home.appendingPathComponent("Library/Caches/com.example.app/escape"),
      withDestinationURL: outside)

    // Age the inactive projects; contents first, folders last.
    for project in ["Projects/old", "Projects/nopkg"] {
      let dir = home.appendingPathComponent(project)
      let paths = FileManager.default.subpaths(atPath: dir.path) ?? []
      for sub in paths.sorted(by: { $0.count > $1.count }) {
        try touch(dir.appendingPathComponent(sub), old)
      }
      try touch(dir, old)
    }
  }

  func write(_ path: String, _ size: Int) throws {
    let url = home.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(count: size).write(to: url)
  }

  func touch(_ url: URL, _ date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
  }

  func context(tree: FileTree?, exclusions: [String] = []) -> CleanupContext {
    let now = now
    return CleanupContext(
      home: home, tree: tree, minimumAgeDays: 90, exclusions: exclusions, now: now,
      runningBundleIDs: ["com.example.running"],
      appURL: { id in
        id.hasPrefix("com.example.")
          ? URL(fileURLWithPath: "/Applications/\(id == "com.example.app" ? "Example" : "Running").app")
          : nil
      },
      addedDate: { url in
        url.lastPathComponent.hasPrefix("old") ? now.addingTimeInterval(-200 * 86_400) : now
      },
      usesTools: false)
  }

  func scan() throws -> FileTree {
    try #require(DiskScanner(root: home).run())
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

private func names(_ category: CleanupCategory?) -> Set<String> {
  Set(category?.items.map(\.name) ?? [])
}

@Test func analyzerFindsEveryFileCategory() throws {
  let fixture = try CleanupFixture()
  defer { fixture.remove() }
  let categories = CleanupAnalyzer.analyzeFiles(fixture.context(tree: try fixture.scan()))
  let byKind = Dictionary(uniqueKeysWithValues: categories.map { ($0.kind, $0) })

  #expect(categories.map(\.kind) == [.xcode, .nodeModules, .appCaches, .trash, .logs, .downloads])

  let xcode = try #require(byKind[.xcode])
  #expect(names(xcode) == ["DerivedData", "iOS DeviceSupport", "Archives"])
  #expect(xcode.items.first { $0.name == "Archives" }?.safety == .review)
  #expect(!xcode.safeItems.contains { $0.name == "Archives" })
  #expect(xcode.mode == .permanent)

  // Only the stale project with a package.json, counted at its top level.
  let node = try #require(byKind[.nodeModules])
  #expect(names(node) == ["old"])
  guard case .files(let files) = node.items[0].target else {
    Issue.record("node_modules should be a file target")
    return
  }
  #expect(files.map(\.url.lastPathComponent) == ["node_modules"])
  #expect(files[0].fileCount == 2)

  // Installed app and known tool; not the running app or a system daemon.
  #expect(names(byKind[.appCaches]) == ["Example", "Homebrew"])

  #expect(names(byKind[.trash]) == ["Файлы старше 30 дней", "Остальное"])
  #expect(byKind[.trash]?.mode == .permanent)
  #expect(names(byKind[.logs]) == ["DiagnosticReports", "Журналы приложений"])

  let downloads = try #require(byKind[.downloads])
  #expect(downloads.safety == .review)
  #expect(downloads.mode == .trash)
  #expect(downloads.safeItems.isEmpty)
  #expect(downloads.items.count == 3)
  #expect(downloads.objectCount == 3)
}

@Test func analyzerFallsBackToFileSystem() throws {
  let fixture = try CleanupFixture()
  defer { fixture.remove() }
  let withTree = CleanupAnalyzer.analyzeFiles(fixture.context(tree: try fixture.scan()))
  let withoutTree = CleanupAnalyzer.analyzeFiles(fixture.context(tree: nil))

  // node_modules needs the tree; everything else is measured directly.
  #expect(!withoutTree.contains { $0.kind == .nodeModules })
  for category in withoutTree {
    let scanned = try #require(withTree.first { $0.kind == category.kind })
    #expect(category.size == scanned.size, "\(category.kind)")
    #expect(Set(category.items.map(\.id)) == Set(scanned.items.map(\.id)))
  }
}

@Test func analyzerRespectsExclusions() throws {
  let fixture = try CleanupFixture()
  defer { fixture.remove() }
  let tree = try fixture.scan()
  let home = fixture.home.path
  let categories = CleanupAnalyzer.analyzeFiles(
    fixture.context(
      tree: tree,
      exclusions: [
        home + "/Projects/old", home + "/Library/Caches/Homebrew/",
        home + "/Library/Developer/Xcode/DerivedData/App-abc/Build",
      ]))
  #expect(!categories.contains { $0.kind == .nodeModules })
  #expect(names(categories.first { $0.kind == .appCaches }) == ["Example"])
  // Removing App-abc would take the excluded Build folder with it.
  #expect(!names(categories.first { $0.kind == .xcode }).contains("DerivedData"))
}

@Test func runnerDeletesWithoutLeavingTheTarget() async throws {
  let fixture = try CleanupFixture()
  defer { fixture.remove() }
  let categories = CleanupAnalyzer.analyzeFiles(fixture.context(tree: try fixture.scan()))
  let chosen: Set<CleanupCategory.Kind> = [.xcode, .nodeModules, .appCaches, .logs]
  let steps = categories.filter { chosen.contains($0.kind) }
    .map { CleanupStep(category: $0, items: $0.safeItems) }
  let runner = CleanupRunner(steps: steps, allowedRoot: fixture.home)
  let result = await runner.run()

  let fm = FileManager.default
  let home = fixture.home
  #expect(!fm.fileExists(atPath: home.appendingPathComponent("Library/Developer/Xcode/DerivedData/App-abc").path))
  #expect(!fm.fileExists(atPath: home.appendingPathComponent("Projects/old/node_modules").path))
  #expect(!fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/com.example.app/cache.db").path))
  // Contents go, the folders apps expect stay.
  #expect(fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/com.example.app").path))
  #expect(fm.fileExists(atPath: home.appendingPathComponent("Library/Developer/Xcode/DerivedData").path))
  // Review items and other rules are untouched.
  #expect(fm.fileExists(atPath: home.appendingPathComponent("Library/Developer/Xcode/Archives/2024-01-01").path))
  #expect(fm.fileExists(atPath: home.appendingPathComponent("Projects/fresh/node_modules").path))
  #expect(fm.fileExists(atPath: home.appendingPathComponent("Library/Caches/com.example.running/data").path))
  // The symlink went, its target did not.
  #expect(fm.fileExists(atPath: fixture.outside.appendingPathComponent("keep.txt").path))

  #expect(result.outcome.failed.isEmpty)
  #expect(!result.wasCancelled)
  #expect(Set(result.cleanedKinds) == chosen)
  #expect(result.freedBytes > 0)
  #expect(result.freedBytes == result.outcome.freedBytes)
  let progress = runner.progress
  #expect(progress.isFinished)
  #expect(progress.steps.allSatisfy { $0.state == .done })
  #expect(progress.freedBytes == result.freedBytes)
  #expect(progress.objectsDone == result.objectsRemoved)
}

@Test func runnerRefusesUnsafeTargets() throws {
  let fixture = try CleanupFixture()
  defer { fixture.remove() }
  let runner = CleanupRunner(steps: [], allowedRoot: fixture.home)
  #expect(!runner.isSafeTarget(fixture.outside.appendingPathComponent("keep.txt")))
  #expect(!runner.isSafeTarget(fixture.home))
  #expect(!runner.isSafeTarget(fixture.home.appendingPathComponent("Library")))
  #expect(!runner.isSafeTarget(fixture.home.appendingPathComponent("Library/../../outside/keep.txt")))
  #expect(!runner.isSafeTarget(fixture.home.appendingPathComponent("Library/Containers/com.docker.docker/Data/Docker.raw")))
  // Through the symlink into `outside`.
  #expect(!runner.isSafeTarget(fixture.home.appendingPathComponent("Library/Caches/com.example.app/escape/keep.txt")))
  #expect(runner.isSafeTarget(fixture.home.appendingPathComponent("Library/Caches/com.example.app/escape")))
  #expect(runner.isSafeTarget(fixture.home.appendingPathComponent("Downloads/old-notes.txt")))
}

@Test func cancelledRunRemovesNothing() async throws {
  let fixture = try CleanupFixture()
  defer { fixture.remove() }
  let categories = CleanupAnalyzer.analyzeFiles(fixture.context(tree: nil))
  let runner = CleanupRunner(
    steps: categories.map { CleanupStep(category: $0, items: $0.items) }, allowedRoot: fixture.home)
  runner.cancel()
  let result = await runner.run()
  #expect(result.wasCancelled)
  #expect(result.outcome.removed.isEmpty)
  #expect(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".Trash/old-photo.jpg").path))
}

@Test func dockerReportParsing() throws {
  let json = """
    {"Images":[
      {"Containers":"0","ID":"sha256:aaa","Repository":"postgres","Tag":"15","Size":"412MB","UniqueSize":"400MB"},
      {"Containers":"0","ID":"sha256:aaa","Repository":"postgres","Tag":"latest","Size":"412MB","UniqueSize":"400MB"},
      {"Containers":"2","ID":"sha256:bbb","Repository":"node","Tag":"20","Size":"1.2GB","UniqueSize":"1GB"},
      {"Containers":"0","ID":"sha256:ccc","Repository":"<none>","Tag":"<none>","Size":"12.5kB","UniqueSize":"12.5kB"}
    ],
    "Volumes":[
      {"Links":"0","Name":"old_pgdata","Size":"2.2GB"},
      {"Links":"1","Name":"live","Size":"1GB"}
    ]}
    """
  let report = try #require(DockerInspector.parseSystemDF(Data(json.utf8)))
  #expect(report.unusedImages.count == 2)
  let postgres = try #require(report.unusedImages.first { $0.repository == "postgres" })
  #expect(postgres.references == ["postgres:15", "postgres:latest"])
  #expect(postgres.size == 400_000_000)
  #expect(report.unusedImages.first { $0.isDangling }?.references == ["sha256:ccc"])
  #expect(report.danglingVolumes.map(\.name) == ["old_pgdata"])

  let category = try #require(CleanupAnalyzer.dockerCategory(report, docker: "/usr/bin/false"))
  #expect(category.kind == .docker)
  #expect(category.items.first { $0.id == "docker.volumes" }?.safety == .review)
  #expect(category.safeItems.count == 2)

  #expect(DockerInspector.parseSize("1.23GB") == 1_230_000_000)
  #expect(DockerInspector.parseSize("0B") == 0)
  #expect(DockerInspector.parseSize("N/A") == nil)
}

@Test func simulatorSelection() throws {
  let json = """
    {"devices":{
      "com.apple.CoreSimulator.SimRuntime.iOS-18-2":[
        {"udid":"A","name":"iPhone 16","state":"Shutdown","isAvailable":true,"lastBootedAt":"2026-10-20T10:00:00Z"}
      ],
      "com.apple.CoreSimulator.SimRuntime.iOS-17-5":[
        {"udid":"B","name":"iPhone 15","state":"Shutdown","isAvailable":true,"dataPath":"/x/Devices/B/data"},
        {"udid":"C","name":"iPhone 15 Pro","state":"Booted","isAvailable":true},
        {"udid":"D","name":"iPad","state":"Shutdown","isAvailable":true,"lastBootedAt":"2026-10-25T10:00:00.123Z"}
      ],
      "com.apple.CoreSimulator.SimRuntime.watchOS-9-1":[
        {"udid":"E","name":"Watch","state":"Shutdown","isAvailable":false}
      ]
    }}
    """
  let devices = try #require(SimulatorInspector.parse(Data(json.utf8)))
  #expect(devices.count == 5)
  #expect(devices.first { $0.udid == "D" }?.lastBooted != nil)
  let cutoff = ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")!
  let removable = SimulatorInspector.removable(devices, bootedBefore: cutoff)
  // Old runtime and idle (B), unavailable (E); not the newest (A), booted
  // (C) or recently used (D).
  #expect(Set(removable.map(\.udid)) == ["B", "E"])
  #expect(SimulatorInspector.Runtime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-17-5")?.displayName == "iOS 17.5")
}
