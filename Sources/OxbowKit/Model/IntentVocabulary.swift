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

  /// **Literal strings, not a computation over `label`.**
  /// `appintentsmetadataprocessor` — the Xcode build tool that statically
  /// extracts `AppEnum` metadata for Shortcuts and Spotlight — parses this
  /// property's source without executing it, and needs the title for each
  /// case to be a compile-time string literal. Two things this replaced
  /// both failed that, confirmed against a real `xcodebuild test` (which
  /// `swift test` cannot, since it never runs this tool):
  ///
  /// - `Dictionary(uniqueKeysWithValues: allCases.map { ... })` isn't
  ///   `[key: value, ...]` bracket syntax at all, so the whole property
  ///   read as "not a dictionary" and every case as missing.
  /// - `[.best: DisplayRepresentation(title: LocalizedStringResource(
  ///   stringLiteral: QualityCap.best.label)), ...]` fixed the bracket
  ///   syntax but still failed per-case ("must be initialized with a call
  ///   to its initializer or a string literal") — reading the *value*
  ///   through the runtime-computed `label` property is exactly what it
  ///   cannot follow.
  ///
  /// So the wording is duplicated here, deliberately — the same literal
  /// form `DownloadOutput` and `ChatSize` already use below, since neither
  /// has a `label` to read either. `IntentVocabularyTests.
  /// theQualityCapReusesItsOwnLabel` is what keeps this copy from drifting
  /// silently: it compares each literal below against `label` at runtime
  /// and fails the moment the two disagree.
  public static var caseDisplayRepresentations: [QualityCap: DisplayRepresentation] {
    [
      .best: "Best available",
      .p1080: "Up to 1080p",
      .p720: "Up to 720p",
      .p480: "Up to 480p",
      .p360: "Up to 360p",
    ]
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
