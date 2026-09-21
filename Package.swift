// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "SysPulse",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(
      name: "SysPulse",
      path: "Sources/SysPulse",
      swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
    )
  ]
)
