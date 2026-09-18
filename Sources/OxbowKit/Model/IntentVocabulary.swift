import AppIntents
import Foundation

/// Stored preferences exposed to Shortcuts and Spotlight. Case identifiers persist in saved
/// shortcuts; preserve them. Display wording stays intent-specific where intake uses contextual
/// labels.

extension QualityCap: AppEnum {
  public static var typeDisplayRepresentation: TypeDisplayRepresentation { "Quality" }

  /// The metadata processor requires literal dictionary entries and literal titles; map-based
  /// dictionaries and computed labels fail Xcode extraction. Keep duplicated quality labels
  /// aligned through IntentVocabularyTests.
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
