import Darwin
import Foundation
import Testing

@testable import SectorCore

private let mb = 1_000_000

private func randomData(_ count: Int) -> Data {
  var data = Data(count: count)
  data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, count) }
  return data
}

/// Temp folder with duplicates, a same-size impostor and an APFS clone.
private func makeFixture() throws -> URL {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("sector-dup-\(UUID().uuidString)")
  for dir in ["Documents", "Downloads", "Desktop", "Other", ".hidden", "node_modules", "Excluded"]
  {
    try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
  }
  let original = randomData(3 * mb)
  try original.write(to: root.appendingPathComponent("Documents/photo.heic"))
  try original.write(to: root.appendingPathComponent("Downloads/photo.heic"))
  try original.write(to: root.appendingPathComponent("Desktop/photo copy.heic"))
  // Same size, same first and last 64 KB, different middle.
  var impostor = original
  impostor[impostor.count / 2] ^= 0xFF
  try impostor.write(to: root.appendingPathComponent("Other/impostor.heic"))
  // Copies in skipped places.
  try original.write(to: root.appendingPathComponent(".hidden/photo.heic"))
  try original.write(to: root.appendingPathComponent("node_modules/photo.heic"))
  try original.write(to: root.appendingPathComponent("Excluded/photo.heic"))
  // Small identical files stay below the threshold.
  let small = randomData(10_000)
  try small.write(to: root.appendingPathComponent("Documents/small.txt"))
  try small.write(to: root.appendingPathComponent("Other/small.txt"))
  // A pair that differs only in length class: unique sizes.
  try randomData(2 * mb).write(to: root.appendingPathComponent("Other/unique.bin"))
  return root
}

private func finder(_ root: URL, excluded: [String] = []) throws -> DuplicateFinder {
  let tree = try #require(DiskScanner(root: root).run())
  let options = DuplicateFinder.Options(
    minSize: UInt64(mb), excludedPaths: excluded, homePath: root.path, maxConcurrency: 2)
  return DuplicateFinder(tree: tree, options: options)
}

@Test func findsIdenticalFilesOnly() throws {
  let root = try makeFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let finder = try finder(root, excluded: [root.appendingPathComponent("Excluded").path])
  let groups = try #require(finder.run())

  #expect(groups.count == 1)
  let group = try #require(groups.first)
  let names = Set(group.files.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().lastPathComponent })
  #expect(names == ["Documents", "Downloads", "Desktop"])
  #expect(group.size == UInt64(3 * mb))
  #expect(group.id.count == 64)
  #expect(finder.progress.phase == .finished)
  #expect(finder.progress.hashedBytes == finder.progress.totalBytes)
  #expect(finder.progress.hashedBytes > 0)
}

@Test func autoOriginalPrefersSettledFolders() throws {
  let root = try makeFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let groups = try #require(try finder(root, excluded: [root.appendingPathComponent("Excluded").path]).run())
  let group = try #require(groups.first)
  let keep = try #require(group.autoOriginal(home: root.path))
  #expect(keep.hasSuffix("Documents/photo.heic"))
  #expect(group.waste(keeping: keep) >= UInt64(2 * mb))

  // Only transient copies: the oldest wins.
  let old = DuplicateFile(
    path: root.path + "/Downloads/a", size: 1, allocatedSize: 1, privateSize: 1,
    created: Date(timeIntervalSince1970: 100), modified: Date(timeIntervalSince1970: 100))
  var new = old
  new.path = root.path + "/Desktop/b"
  new.created = Date(timeIntervalSince1970: 200)
  let transient = DuplicateGroup(id: "x", size: 1, files: [new, old])
  #expect(transient.autoOriginal(home: root.path) == old.path)
}

@Test func excludedFolderCopiesAreSkipped() throws {
  let root = try makeFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let withExcluded = try #require(try finder(root).run())
  #expect(withExcluded.first?.files.count == 4)
  let paths = try finder(root, excluded: [root.appendingPathComponent("Excluded").path])
    .candidatePaths()
  #expect(!paths.contains { $0.contains("/.hidden/") || $0.contains("/node_modules/") })
  #expect(!paths.contains { $0.contains("/Excluded/") })
  #expect(!paths.contains { $0.hasSuffix("small.txt") })
}

@Test func clonesFreeNothing() throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("sector-clone-\(UUID().uuidString)")
  try fm.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: root) }
  let a = root.appendingPathComponent("a.mov")
  let clone = root.appendingPathComponent("clone.mov")
  try randomData(4 * mb).write(to: a)
  guard clonefile(a.path, clone.path, 0) == 0 else { return }  // Not APFS.

  // Only clones: nothing to reclaim, so no group.
  #expect(try finder(root).run()?.isEmpty == true)

  // A real copy alongside the clones is worth deleting.
  try fm.copyItem(at: a, to: root.appendingPathComponent("copy.mov"))
  let copy = root.appendingPathComponent("copy.mov")
  if FileMetadata.privateSize(copy.path) ?? 0 < UInt64(mb) {
    // copyItem cloned it as well; write a genuine copy.
    try fm.removeItem(at: copy)
    try Data(contentsOf: a).write(to: copy)
  }
  let groups = try #require(try finder(root).run())
  let group = try #require(groups.first)
  #expect(group.files.count == 3)
  let cloneFile = try #require(group.files.first { $0.path.hasSuffix("clone.mov") })
  #expect(cloneFile.isClone)
  let realCopy = try #require(group.files.first { $0.path.hasSuffix("copy.mov") })
  #expect(!realCopy.isClone)
  // Keeping the original frees the real copy's blocks, not the clone's.
  let original = try #require(group.files.first { $0.path.hasSuffix("a.mov") })
  let waste = group.waste(keeping: original.path)
  #expect(waste >= UInt64(4 * mb) && waste < UInt64(5 * mb))
}

@Test func cancellationStopsTheRun() throws {
  let root = try makeFixture()
  defer { try? FileManager.default.removeItem(at: root) }
  let finder = try finder(root)
  finder.cancel()
  #expect(finder.run() == nil)
}
