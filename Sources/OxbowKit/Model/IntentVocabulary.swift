import AppIntents
import Foundation

/// The three stored preferences, as Shortcuts and Spotlight see them.
///
/// **Why these types were already the right shape.** `docs/design/settings.md`
/// §3.1 refused to store a rendition name because rendition names are
/// per-video and unstable — `1080p60`, `720p0-1`, `1080p60-Portrait-1` — and
/// stored a *policy* instead. A per-video name could not have been an intent
/// parameter at all; a policy can, and `QualityLadder.resolve` is what turns
/// it back into this video's rendition with no human present. The ladder
/// built for the Settings window is what makes an automatable quality
/// parameter possible.
///
/// **Case identifiers are storage.** Shortcuts persists them inside saved
/// shortcuts. See `IntentVocabularyTests`.
///
/// `DownloadOutput` and `ChatSize` carry their display names here rather than
/// gaining a `label` the way `QualityCap` has one. `SettingsView` writes both
/// inline, and `IntakeWindow` renders `DownloadOutput` differently again for
/// a clip ("Clip + chat") — so a single `label` could not serve the intake
/// anyway, and three duplicated words beat refactoring a picker whose wording
/// is context-dependent.

extension QualityCap: AppEnum {
  public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Quality" }

  public static var caseDisplayRepresentations: [QualityCap: DisplayRepresentation] {
    // Built from `label`, so the Shortcuts wording and the Settings window's
    // wording cannot drift apart. `label` is a runtime `String`, not a
    // literal, so it goes through `LocalizedStringResource(stringLiteral:)`
    // explicitly rather than through `DisplayRepresentation`'s
    // `ExpressibleByStringLiteral` conformance, which exists for literals
    // like the ones below, not for values computed at runtime.
    Dictionary(uniqueKeysWithValues: allCases.map {
      ($0, DisplayRepresentation(title: LocalizedStringResource(stringLiteral: $0.label)))
    })
  }
}

extension DownloadOutput: AppEnum {
  public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Output" }

  public static var caseDisplayRepresentations: [DownloadOutput: DisplayRepresentation] {
    [.videoWithChat: "Video + chat", .video: "Video only"]
  }
}

extension ChatSize: AppEnum {
  public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Chat Text Size" }

  public static var caseDisplayRepresentations: [ChatSize: DisplayRepresentation] {
    [.small: "Small", .medium: "Medium", .large: "Large"]
  }
}
