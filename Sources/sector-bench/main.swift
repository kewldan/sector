import Foundation
import SectorCore

// Usage: sector-bench <path> [gentle|balanced|maximum]
let args = CommandLine.arguments
let path = args.count > 1 ? args[1] : NSHomeDirectory()
let load = args.count > 2 ? ScanLoad(rawValue: args[2]) ?? .balanced : .balanced

let scanner = DiskScanner(root: URL(fileURLWithPath: path), load: load)
let start = Date()
guard let tree = scanner.run() else { exit(1) }
let elapsed = Date().timeIntervalSince(start)
let p = scanner.progress
print(
  String(
    format: "%@: %.2f s, %d nodes, %d files, %d dirs, %d denied, %.2f GB, tree %.1f MB",
    path, elapsed, tree.count, p.files, p.directories, p.deniedDirectories,
    Double(tree.size(FileTree.root)) / 1e9, Double(tree.memoryFootprint) / 1e6))
for child in tree.sortedChildren(FileTree.root).prefix(8) {
  print(String(format: "  %10.2f GB  %@", Double(tree.size(child)) / 1e9, tree.name(child)))
}

let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent("sector-bench-tree.bin")
var t0 = Date()
try tree.write(to: cacheURL)
let writeTime = Date().timeIntervalSince(t0)
t0 = Date()
let loaded = FileTree.read(from: cacheURL)
let readTime = Date().timeIntervalSince(t0)
let bytes = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.size] as? Int) ?? 0
print(
  String(
    format: "cache: %.1f MB, write %.2f s, read %.2f s, ok=%@", Double(bytes) / 1e6, writeTime,
    readTime, loaded?.count == tree.count ? "yes" : "no"))
try? FileManager.default.removeItem(at: cacheURL)
