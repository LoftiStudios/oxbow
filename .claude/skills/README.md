# Vendored agent skills

Checked in so every contributor's agent works from the same Swift/SwiftUI/macOS
conventions. Vendored verbatim from upstream — do not hand-edit; refresh from source.

| Dir | Source | Notes |
|---|---|---|
| `swiftui-pro/` | https://github.com/twostraws/swiftui-agent-skill (MIT) | Paul Hudson. SwiftUI review: modern API, data flow, perf, a11y. Written for iOS 26 defaults — for Oxbow read "macOS 26" and ignore its UIKit-avoidance phrasing about iOS. |
| `macos-design/` | https://github.com/ceorkm/macos-design-skill | Native macOS layout, interaction, visual design. Its "Implementation Notes" cover web/Electron simulation — ignore those; we ship real AppKit/SwiftUI. |
| `swift/` | https://swift.airbnb.tech/SKILL.md | Airbnb Swift Style Guide, minus rules a formatter already enforces. |

Refresh: re-download from the sources above and replace the directory contents.
`swiftui-pro/references` is a symlink upstream; it is materialised as a real
directory here.
