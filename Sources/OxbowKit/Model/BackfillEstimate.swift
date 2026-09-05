import Foundation

/// What taking a set of archives will cost, roughly.
///
/// **Deliberately rougher than `SpaceEstimate`, and the UI must say so.**
/// `SpaceEstimate` prices one job from a real `StreamQuality` — a rendition
/// with actual pixel dimensions, fetched per video. A channel's feed carries
/// no renditions at all (`docs/twitch-channel-api.md` §3): they come from the
/// CLI's per-video `info` verb, one process spawn each, and pricing a hundred
/// archives that way would mean a hundred spawns before the user has agreed
/// to anything.
///
/// So this builds a *nominal* `StreamQuality` from the cap alone — Twitch's
/// standard rendition for that ceiling, not any particular video's real one —
/// and prices it through the exact same `SpaceEstimate` arithmetic intake
/// uses (`IntakeModel.estimate(for:over:)`), rather than a formula of its
/// own. That is honest as long as nothing presents it with intake's
/// precision, which is why every caller says "about"; once a video's real
/// renditions are in hand — intake's situation — this nominal figure is
/// meant to be replaced outright, not refined.
///
/// **Nominal is the right side to be wrong on, with one exception.** A real
/// broadcast's bitrate sits around Twitch's target for its rendition, not
/// reliably under it, so this cannot promise it never underestimates. But for
/// a number someone is deciding disk space against, overestimating is the
/// safer failure — a job that declines to start on a false "won't fit" costs
/// an override click, while one that starts on a false "will fit" costs a
/// download that runs out of room partway through. (`SpaceEstimate
/// .chatRenderBitsPerSecond`'s own comment reaches the same conclusion for
/// the same kind of decision — this type used to argue the opposite for
/// `.best` and that was simply wrong.) The acknowledged exception is `.best`
/// itself: it is priced at 1080p because it admits anything and a broadcast
/// above 1080p is rare, but a rare one would then be underpriced. That is a
/// deliberate, recorded trade for keeping one ladder rather than a reason to
/// call the general rule anything other than "overestimate."
///
/// **Takes archives, never a count.** The feed's own item-count field
/// (`totalCount`) overcounts the edges actually returned by up to two
/// (`docs/twitch-channel-api.md` §5.1), so `docs/design/channel-watching.md`
/// §3.3 requires the total be summed from what is in hand. There is
/// deliberately no initialiser that accepts a number.
public struct BackfillEstimate: Equatable, Sendable {

  public let count: Int
  public let duration: Duration
  public let bytes: Int64

  public init(archives: [ChannelArchive], cap: QualityCap, output: DownloadOutput) {
    count = archives.count
    duration = archives.reduce(Duration.zero) { $0 + $1.duration }

    let quality = Self.nominalQuality(for: cap)
    // Built once, outside the sum: the geometry depends only on the nominal
    // quality, which is the same for every archive here.
    let geometry = output == .videoWithChat ? CompositeGeometry(quality: quality) : nil

    bytes = archives.reduce(Int64(0)) { total, archive in
      total + SpaceEstimate(quality: quality, duration: archive.duration, composite: geometry).delivered
    }
  }

  /// Twitch's standard rendition for a cap, since the channel feed has no
  /// real one to read for any of these archives yet.
  ///
  /// Nominal rather than measured — a stated target, not a bitrate observed
  /// off an actual stream — which is the reverse of how `SpaceEstimate`
  /// itself is calibrated everywhere else. That is acceptable only here,
  /// because this whole type exists to be replaced by a real
  /// `StreamQuality` (and hence a real `SpaceEstimate`) the moment intake has
  /// one; nothing downstream of `BackfillEstimate` treats it as more precise
  /// than "about".
  private static func nominalQuality(for cap: QualityCap) -> StreamQuality {
    switch cap {
    case .best, .p1080:
      return StreamQuality(name: "1080p30", resolution: "1920x1080", bitsPerSecond: 6_000_000)
    case .p720:
      return StreamQuality(name: "720p30", resolution: "1280x720", bitsPerSecond: 3_500_000)
    case .p480:
      return StreamQuality(name: "480p30", resolution: "852x480", bitsPerSecond: 1_400_000)
    case .p360:
      return StreamQuality(name: "360p30", resolution: "640x360", bitsPerSecond: 700_000)
    }
  }
}
