// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "RexRadar",
  platforms: [.macOS("26.0")],
  targets: [
    .executableTarget(name: "RexRadar", path: "Sources/RexRadar")
  ]
)
