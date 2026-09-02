import Foundation

/// A standing quality preference, as distinct from one video's rendition.
///
/// Renditions are named per video — `1080p60`, `480p30-1`, `720p0-1`,
/// `1080p60-Portrait-1` — and some carry no resolution at all, so no name is
/// stable across two videos and none is worth storing. A ceiling is.
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

  /// Every rung with a ceiling, highest first.
  static var rungs: [QualityCap] { [.p1080, .p720, .p480, .p360] }
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

    if let best = sized.filter({ $0.1 <= ceiling }).max(by: { $0.1 < $1.1 }) {
      return best.0.name
    }
    // Nothing at or below the ceiling. A video that only offers more than the
    // user usually wants should still download.
    return sized.min(by: { $0.1 < $1.1 })?.0.name ?? ""
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
    return QualityCap.rungs.first { side >= ($0.ceiling ?? 0) } ?? .p360
  }
}
