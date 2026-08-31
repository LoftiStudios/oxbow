// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "OxbowKit",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "OxbowKit", targets: ["OxbowKit"]),
  ],
  targets: [
    .target(
      name: "OxbowKit",
      swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "OxbowKitTests",
      dependencies: ["OxbowKit"],
      resources: [.copy("Fixtures")],
      swiftSettings: [.swiftLanguageMode(.v6)]),
  ])
