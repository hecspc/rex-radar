// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "RexRadar",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(name: "RexRadar", path: "Sources/RexRadar")
  ]
)
