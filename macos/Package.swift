// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "RexRadar",
  platforms: [.macOS("26.0")],
  targets: [
    // The app's own sources plus Shared; the widget only builds with Xcode (project.yml).
    .executableTarget(name: "RexRadar", path: "Sources", exclude: ["RexRadarWidget"])
  ]
)
