import Foundation
import Testing

@testable import SectorCore

private struct Fixture {
  var root: URL
  var apps: URL { root.appendingPathComponent("Applications") }
  var library: URL { root.appendingPathComponent("Library") }
  var inventory: AppInventory { AppInventory(searchRoots: [apps], libraryRoot: library) }
}

private func makeBundle(_ url: URL, id: String, version: String, copyright: String? = nil) throws {
  let fm = FileManager.default
  try fm.createDirectory(
    at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
  var info: [String: Any] = [
    "CFBundleIdentifier": id, "CFBundleShortVersionString": version,
    "CFBundleName": url.deletingPathExtension().lastPathComponent,
  ]
  if let copyright { info["NSHumanReadableCopyright"] = copyright }
  try (info as NSDictionary).write(to: url.appendingPathComponent("Contents/Info.plist"))
  try Data(count: 50_000).write(to: url.appendingPathComponent("Contents/MacOS/binary"))
}

private func makeFixture() throws -> Fixture {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("sector-apps-\(UUID().uuidString)")
  let f = Fixture(root: root)
  try makeBundle(
    f.apps.appendingPathComponent("Foo.app"), id: "com.example.foo", version: "2.4.1",
    copyright: "Copyright © 2021–2026 Example Inc. All rights reserved.")
  try makeBundle(
    f.apps.appendingPathComponent("Utilities/Bar.app"), id: "com.example.bar", version: "1.0")
  try makeBundle(
    f.apps.appendingPathComponent("Deep/Nested/Baz.app"), id: "com.example.baz", version: "1.0")

  let lib = f.library
  func dir(_ path: String, bytes: Int = 0) throws {
    let url = lib.appendingPathComponent(path)
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    if bytes > 0 { try Data(count: bytes).write(to: url.appendingPathComponent("data")) }
  }
  func file(_ path: String) throws {
    let url = lib.appendingPathComponent(path)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(count: 100).write(to: url)
  }
  try dir("Application Support/com.example.foo", bytes: 200_000)
  try dir("Application Support/Foo", bytes: 10_000)
  try dir("Caches/com.example.foo", bytes: 30_000)
  try dir("Containers/com.example.foo")
  try dir("Group Containers/ABCDE12345.com.example.foo")
  try dir("Group Containers/group.com.example.foo")
  try dir("Group Containers/ABCDE12345.Shared")
  try dir("Saved Application State/com.example.foo.savedState")
  try dir("HTTPStorages/com.example.foo")
  try dir("WebKit/com.example.foo")
  try dir("Logs/Foo")
  try file("Preferences/com.example.foo.plist")
  try file("Preferences/com.example.foobar.plist")
  try file("Preferences/ByHost/com.example.foo.1234-5678.plist")
  try file("Cookies/com.example.foo.binarycookies")
  try file("LaunchAgents/com.example.foo.helper.plist")
  try file("LaunchAgents/com.other.agent.plist")
  try dir("Caches/com.example.foobar")
  return f
}

@Test func discoversBundlesOneLevelDeep() throws {
  let f = try makeFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let names = f.inventory.bundleURLs().map { $0.lastPathComponent }
  #expect(Set(names) == ["Foo.app", "Bar.app"])
}

@Test func collectsRelatedData() throws {
  let f = try makeFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let app = try #require(f.inventory.app(at: f.apps.appendingPathComponent("Foo.app")))
  #expect(app.name == "Foo")
  #expect(app.bundleID == "com.example.foo")
  #expect(app.version == "2.4.1")
  #expect(app.vendor == "Example Inc")
  #expect(app.size >= 50_000)

  let lib = f.library.standardizedFileURL.path
  let paths = Set(app.related.map { String($0.url.path.dropFirst(lib.count + 1)) })
  #expect(
    paths == [
      "Application Support/com.example.foo", "Application Support/Foo",
      "Caches/com.example.foo", "Containers/com.example.foo",
      "Group Containers/ABCDE12345.com.example.foo", "Group Containers/group.com.example.foo",
      "Saved Application State/com.example.foo.savedState", "HTTPStorages/com.example.foo",
      "WebKit/com.example.foo", "Logs/Foo", "Preferences/com.example.foo.plist",
      "Preferences/ByHost/com.example.foo.1234-5678.plist",
      "Cookies/com.example.foo.binarycookies", "LaunchAgents/com.example.foo.helper.plist",
    ])
  let support = try #require(
    app.related.first { $0.url.lastPathComponent == "com.example.foo" && $0.kind == .applicationSupport })
  #expect(support.size >= 200_000)
  #expect(app.totalSize == app.size + app.relatedSize)
}

@Test func sizesComeFromTheLookupWhenAvailable() throws {
  let f = try makeFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let app = try #require(
    f.inventory.app(at: f.apps.appendingPathComponent("Foo.app")) { _ in 7 })
  #expect(app.size == 7)
  #expect(app.related.allSatisfy { $0.size == 7 })
}

@Test func groupContainerRules() {
  let id = "com.vendor.product.mac"
  #expect(AppInventory.groupContainer("group.com.vendor.product.mac", matches: id, teamID: nil))
  #expect(AppInventory.groupContainer("TEAM123456.com.vendor.product.mac", matches: id, teamID: nil))
  #expect(AppInventory.groupContainer("TEAM123456.com.vendor.product", matches: id, teamID: "TEAM123456"))
  #expect(!AppInventory.groupContainer("TEAM123456.com.vendor.product", matches: id, teamID: nil))
  #expect(!AppInventory.groupContainer("TEAM123456.Office", matches: id, teamID: "TEAM123456"))
  #expect(!AppInventory.groupContainer("TEAM123456.com.vendor", matches: id, teamID: "TEAM123456"))
}

@Test func vendorParsing() {
  #expect(AppInventory.vendor(fromCopyright: "© 2024 Google LLC. All rights reserved.") == "Google LLC")
  #expect(AppInventory.vendor(fromCopyright: "Copyright 2019-2025, Docker Inc") == "Docker Inc")
  #expect(AppInventory.vendor(fromCopyright: "All rights reserved") == nil)
  #expect(
    AppInventory.vendor(fromCertificate: "Developer ID Application: Google LLC (EQHXZ8M8AV)")
      == "Google LLC")
  #expect(AppInventory.vendor(fromCertificate: "Software Signing") == "Apple")
}

@Test func systemAppsAreNotRemovable() {
  let safari = URL(fileURLWithPath: "/Applications/Safari.app")
  var st = stat()
  guard lstat(safari.path, &st) == 0 else { return }
  #expect(!AppInventory.isRemovable(safari, flags: st.st_flags))
  #expect(!AppInventory.isRemovable(URL(fileURLWithPath: "/System/Applications/Notes.app"), flags: 0))
}
