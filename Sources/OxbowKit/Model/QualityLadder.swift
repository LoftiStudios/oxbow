import Foundation

/// A standing quality preference, as distinct from one video's rendition.
///
/// Renditions are named per video — `1080p60`, `480p30-1`, `720p0-1`,
/// `1080p60-Portrait-1` — and some carry no resolution at all, so no name is
/// stable across two videos and none is worth storing. A ceiling is.
///
/// `Preferences` persists this enum's raw values in `UserDefaults`. Renaming
/// a case is therefore a storage-format change, not a refactor — it silently
/// orphans every saved preference, which falls back to the factory value with
/// no error anywhere. `QualityLadderTests.rawValuesArePersistedAndPinned`
/// pins the exact strings on purpose; if it fails after a rename, fix the
/// case name, not the test.
public enum QualityCap: String, Codable, CaseIterable, Sendable {
  case best
  case p1080
  case p720
  case p480
  case p360

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

  /// Every rung with its ceiling, highest first. Stored as tuples to prevent
  /// accidental introduction of `.best` into the rungs — if `.best` were added
  /// here, bucket would have no ceiling and would match everything, reversing
  /// §3.5's protection against rounding up.
  static var rungs: [(cap: QualityCap, ceiling: Int)] {
    [(cap: .p1080, ceiling: 1080), (cap: .p720, ceiling: 720),
     (cap: .p480, ceiling: 480), (cap: .p360, ceiling: 360)]
  }
}

/// Translates between a stored cap and one video's renditions, in both
/// directions. The two are deliberately not inverses — see
/// `docs/design/settings.md` §3.3.
public enum QualityLadder {

  /// The rendition name a cap selects for this video, or the empty string for
  /// "let the CLI choose", which is what `.best` means and what an empty
  /// rendition list leaves us with.
  ///
  /// `forComposite` excludes renditions `CompositeGeometry` cannot size a chat
  /// column against. Resolution writes a concrete name into the model, and
  /// `IntakeModel.compositeQuality` cannot tell a resolved name from a typed
  /// one — it honours any explicit pick, deliberately. So without this a cap
  /// could hand the user a dead end for a choice they never made.
  ///
  /// The filter overlaps `sized`'s own nil-dimension drop today and bites only
  /// on a rendition with a dimension of 1 (which has a `shortSide` but no usable
  /// `CompositeGeometry`). It is kept as defence rather than as currently-load-bearing
  /// logic.
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
    // Nothing at or below the ceiling. A video that only offers more than the
    // user usually wants should still download.
    return sized.min(by: {
      if $0.1 == $1.1 {
        // Inverted relative to the `max` above, deliberately: `min` returns
        // the element that compares smallest, so the higher bitrate has to
        // compare as *smaller* here to be the one that surfaces. Equal
        // bitrates return false either way, which keeps first-listed.
        return $0.0.bitsPerSecond > $1.0.bitsPerSecond
      }
      return $0.1 < $1.1
    })?.0.name ?? ""
  }

  /// The cap a chosen rendition expresses, or nil when it has no dimensions to
  /// read — the older-clip case, where the caller withholds quality from a
  /// save rather than guessing at it.
  ///
  /// **Always the largest rung at or below the rendition.** Rounding up would
  /// mean a preference set from one video quietly produces larger files than
  /// the user ever asked for, on every video after it.
  public static func bucket(_ quality: StreamQuality) -> QualityCap? {
    guard let side = quality.shortSide else { return nil }
    return QualityCap.rungs.first { side >= $0.ceiling }?.cap ?? .p360
  }
}
