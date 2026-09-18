import Foundation

/// A persistent resolution ceiling; rendition names vary per video. Raw values are the storage
/// format: renaming them requires migration.
/// `QualityLadderTests.rawValuesArePersistedAndPinned` pins these strings.
public enum QualityCap: String, Codable, CaseIterable, Sendable {
  case best
  case p1080
  case p720
  case p480
  case p360

  /// Shared UI wording. Also update the literals in `IntentVocabulary.swift`, which the App
  /// Intents metadata processor requires. `IntentVocabularyTests` checks they agree.
  public var label: String {
    switch self {
    case .best: "Best available"
    case .p1080: "Up to 1080p"
    case .p720: "Up to 720p"
    case .p480: "Up to 480p"
    case .p360: "Up to 360p"
    }
  }

  /// The largest short side this cap admits. Nil for `.best`, which admits
  /// everything.
  public var ceiling: Int? {
    switch self {
    case .best: nil
    case .p1080: 1080
    case .p720: 720
    case .p480: 480
    case .p360: 360
    }
  }

  /// Numeric ceilings, highest first. Excludes `.best`, which has no ceiling and would match
  /// every rendition.
  static var rungs: [(cap: QualityCap, ceiling: Int)] {
    [(cap: .p1080, ceiling: 1080), (cap: .p720, ceiling: 720),
     (cap: .p480, ceiling: 480), (cap: .p360, ceiling: 360)]
  }
}

/// Translates between a stored cap and one video's renditions, in both
/// directions. The two are deliberately not inverses — see
/// `docs/design/settings.md` §3.3.
public enum QualityLadder {

  /// Resolves a cap to a rendition name, or empty for CLI selection (`.best` or no renditions).
  /// For composites, excludes renditions without usable `CompositeGeometry` so a saved cap
  /// cannot select an unusable chat layout.
  public static func resolve(
    _ cap: QualityCap, in qualities: [StreamQuality], forComposite: Bool) -> String
  {
    let usable = forComposite
      ? qualities.filter { CompositeGeometry(quality: $0) != nil }
      : qualities
    guard !usable.isEmpty else { return "" }
    guard let ceiling = cap.ceiling else { return "" }

    let sized = usable.compactMap { quality -> (StreamQuality, Int)? in
      guard let side = quality.shortSide else { return nil }
      return (quality, side)
    }
    guard !sized.isEmpty else { return "" }

    if let best = sized.filter({ $0.1 <= ceiling }).max(by: {
      if $0.1 == $1.1 {
        // Tie-break on bitrate when shortSides match: prefer higher bitrate.
        // When both are 0 (older clips), this preserves list order.
        return $0.0.bitsPerSecond < $1.0.bitsPerSecond
      }
      return $0.1 < $1.1
    }) {
      return best.0.name
    }
    // If no rendition fits the ceiling, choose the smallest available above it.
    return sized.min(by: {
      if $0.1 == $1.1 {
        // For `min`, higher bitrate must compare smaller. Equal bitrates preserve list order.
        return $0.0.bitsPerSecond > $1.0.bitsPerSecond
      }
      return $0.1 < $1.1
    })?.0.name ?? ""
  }

  /// Returns the largest cap at or below a rendition, or nil for unknown dimensions. Never
  /// rounds up: saving a preference must not request larger renditions on later videos.
  public static func bucket(_ quality: StreamQuality) -> QualityCap? {
    guard let side = quality.shortSide else { return nil }
    return QualityCap.rungs.first { side >= $0.ceiling }?.cap ?? .p360
  }
}
