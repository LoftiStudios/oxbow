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
      // TODO: development only. Inter is SIL OFL 1.1, which must ship its licence text with the
      // fonts; if the renderer keeps Inter past Phase 1, add rsms/inter's LICENSE.txt (v4.001)
      // beside them before release. A different typeface may replace it instead.
      resources: [.copy("Resources/Fonts")],
      swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(
      name: "OxbowKitTests",
      dependencies: ["OxbowKit"],
      resources: [.copy("Fixtures")],
      swiftSettings: [.swiftLanguageMode(.v6)]),
  ])
