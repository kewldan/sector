import Foundation
import Testing

@testable import SectorCore

/// Builds a throwaway directory tree and returns its root.
private func makeFixture() throws -> URL {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("sector-\(UUID().uuidString)")
  try fm.createDirectory(at: root.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
  try fm.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
  try Data(count: 100_000).write(to: root.appendingPathComponent("a/big.bin"))
  try Data(count: 5_000).write(to: root.appendingPathComponent("a/b/c/small.txt"))
  try Data(count: 10).write(to: root.appendingPathComponent(".hidden"))
  try Data(count: 1_000).write(to: root.appendingPathComponent("Тест файл.txt"))
  try fm.createSymbolicLink(
    at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("a"))
  try fm.linkItem(
    at: root.appendingPathComponent("a/big.bin"), to: root.appendingPathComponent("hardlink.bin"))
  return root
}

private func allocated(_ url: URL) -> UInt64 {
  var st = stat()
  lstat(url.path, &st)
  return UInt64(st.st_blocks) * 512
}

@Test func scanMatchesStat() throws {
  let root = try makeFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let tree = try #require(DiskScanner(root: root).run())

  let big = try #require(tree.find(path: root.appendingPathComponent("a/big.bin").path))
  // Hard-linked copies share one allocation; whichever is found first owns it.
  let link = try #require(tree.child(FileTree.root, named: "hardlink.bin"))
  #expect(tree.size(big) + tree.size(link) == allocated(root.appendingPathComponent("a/big.bin")))
  #expect(min(tree.size(big), tree.size(link)) == 0)
  #expect(!tree.isDirectory(big))
  #expect(tree.name(big) == "big.bin")
  #expect(tree.path(big) == root.appendingPathComponent("a/big.bin").path)

  let small = try #require(tree.find(path: root.appendingPathComponent("a/b/c/small.txt").path))
  #expect(tree.depth(small) == 4)
  #expect(tree.lineage(small).first == FileTree.root)

  // The hard link is counted once.
  let expected =
    allocated(root.appendingPathComponent("a/big.bin"))
    + allocated(root.appendingPathComponent("a/b/c/small.txt"))
    + allocated(root.appendingPathComponent(".hidden"))
    + allocated(root.appendingPathComponent("Тест файл.txt"))
    + allocated(root.appendingPathComponent("link"))
  #expect(tree.size(FileTree.root) == expected)
  #expect(tree.fileCount(FileTree.root) == 6)
}

@Test func treeInvariants() throws {
  let root = try makeFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let tree = try #require(DiskScanner(root: root, load: .maximum).run())

  for id in 1..<NodeID(tree.count) {
    let parent = try #require(tree.parent(id))
    #expect(parent < id)
    #expect(tree.children(parent).contains(id))
    #expect(tree.size(parent) >= tree.size(id))
  }
  let names = Set(tree.children(FileTree.root).map(tree.name))
  #expect(names == ["a", "empty", ".hidden", "Тест файл.txt", "link", "hardlink.bin"])

  let hidden = try #require(tree.child(FileTree.root, named: ".hidden"))
  #expect(tree.flags(hidden).contains(.hidden))
  let link = try #require(tree.child(FileTree.root, named: "link"))
  #expect(tree.flags(link).contains(.symlink))
  #expect(tree.children(link).isEmpty)
}

@MainActor @Test func removeUpdatesAncestors() throws {
  let root = try makeFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let tree = try #require(DiskScanner(root: root).run())

  let a = try #require(tree.child(FileTree.root, named: "a"))
  let big = try #require(tree.child(a, named: "big.bin"))
  let before = tree.size(FileTree.root)
  let bigSize = tree.size(big)
  tree.remove(big)
  #expect(tree.isRemoved(big))
  #expect(tree.size(FileTree.root) == before - bigSize)
  #expect(!tree.sortedChildren(a).contains(big))
  #expect(tree.find(path: tree.path(big)) == nil)
}

@Test func deniedDirectoriesAreReported() throws {
  let root = try makeFixture()
  let locked = root.appendingPathComponent("locked")
  try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
  chmod(locked.path, 0)
  defer {
    chmod(locked.path, 0o755)
    try? FileManager.default.removeItem(at: root)
  }
  let scanner = DiskScanner(root: root)
  let tree = try #require(scanner.run())
  let node = try #require(tree.child(FileTree.root, named: "locked"))
  #expect(tree.flags(node).contains(.denied))
  #expect(scanner.deniedPaths == [locked.path])
}

@Test func packagesAreFlagged() {
  for name in ["Xcode.app", "Photos Library.photoslibrary", "Влог.FCPBUNDLE"] {
    let bytes = Array(name.utf8)
    let isPackage = bytes.withUnsafeBufferPointer { BulkAttributes.isPackage($0) }
    #expect(isPackage, "\(name)")
  }
  let plain = Array("Documents".utf8)
  #expect(!plain.withUnsafeBufferPointer { BulkAttributes.isPackage($0) })
}

@Test func russianPlurals() {
  let ru = Locale(identifier: "ru_RU")
  #expect(Plural.word(1, "файл", "файла", "файлов", locale: ru) == "файл")
  #expect(Plural.word(3, "файл", "файла", "файлов", locale: ru) == "файла")
  #expect(Plural.word(11, "файл", "файла", "файлов", locale: ru) == "файлов")
  #expect(Plural.word(21, "файл", "файла", "файлов", locale: ru) == "файл")
  #expect(Plural.word(112, "файл", "файла", "файлов", locale: ru) == "файлов")
  #expect(Plural.word(5, "файл", "файла", "файлов", locale: Locale(identifier: "en_US")) == "файлов")
}

@MainActor @Test func cacheRoundTrip() throws {
  let root = try makeFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let tree = try #require(DiskScanner(root: root).run())
  let a = try #require(tree.child(FileTree.root, named: "a"))
  tree.remove(try #require(tree.child(a, named: "big.bin")))

  let file = root.appendingPathComponent("cache/tree.bin")
  try tree.write(to: file)
  let loaded = try #require(FileTree.read(from: file))
  #expect(loaded.count == tree.count)
  #expect(loaded.rootPath == tree.rootPath)
  #expect(Int(loaded.scannedAt.timeIntervalSince1970) == Int(tree.scannedAt.timeIntervalSince1970))
  for id in 0..<NodeID(tree.count) {
    #expect(loaded.name(id) == tree.name(id))
    #expect(loaded.size(id) == tree.size(id))
    #expect(loaded.flags(id) == tree.flags(id))
    #expect(loaded.children(id) == tree.children(id))
  }

  // Truncated files are rejected rather than crashing.
  let data = try Data(contentsOf: file)
  try data.prefix(data.count - 3).write(to: file)
  #expect(FileTree.read(from: file) == nil)
}

@Test func skippedPathsAreNotEntered() throws {
  let root = try makeFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let skipped = root.appendingPathComponent("a/b").path
  let scanner = DiskScanner(root: root, skipPaths: [skipped])
  let tree = try #require(scanner.run())
  let node = try #require(tree.find(path: skipped))
  #expect(tree.flags(node).contains(.denied))
  #expect(tree.children(node).isEmpty)
  #expect(scanner.deniedPaths == [skipped])
  #expect(tree.find(path: root.appendingPathComponent("a/b/c/small.txt").path) == nil)
}

@Test func widgetSnapshotRoundTrip() throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("sector-\(UUID().uuidString)/snapshot.json")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  var snapshot = WidgetSnapshot.preview
  snapshot.date = Date(timeIntervalSince1970: 1_800_000_000)
  #expect(snapshot.save(to: url))
  #expect(WidgetSnapshot.load(from: url) == snapshot)
  #expect(abs(snapshot.usedFraction - 0.876) < 0.001)
  // Test bundles carry no group key, so there is no shared container.
  #expect(WidgetSnapshot.groupIdentifier == nil)
}
