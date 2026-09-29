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
      // Inter, as the CLI embeds it: matching its line breaks needs the same advances.
      // Inter is SIL OFL 1.1, whose licence must travel with the fonts: LICENSE.txt sits beside
      // them, taken from rsms/inter at the commit the fonts name (4.001, git-9221beed3).
      resources: [.copy("Resources/Fonts")],
      swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "OxbowKitTests",
      dependencies: ["OxbowKit"],
      resources: [.copy("Fixtures")],
      swiftSettings: [.swiftLanguageMode(.v6)]),
  ])
