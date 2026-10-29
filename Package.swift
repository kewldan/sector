// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Sector",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "Sector", targets: ["Sector"]),
    .library(name: "SectorCore", targets: ["SectorCore"]),
  ],
  targets: [
    .target(name: "SectorCore"),
    .executableTarget(name: "Sector", dependencies: ["SectorCore"]),
    .executableTarget(name: "sector-bench", dependencies: ["SectorCore"]),
    .testTarget(name: "SectorCoreTests", dependencies: ["SectorCore"]),
  ]
)
