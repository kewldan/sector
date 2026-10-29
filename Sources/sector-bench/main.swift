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
