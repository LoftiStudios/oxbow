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
///
/// **What `bytes` means: everything still held, plus the one job in flight.**
/// It is neither `Σ SpaceEstimate.delivered` nor `Σ SpaceEstimate.total`,
/// because both answer a different question than "will running this backfill
/// fit." `delivered` alone understates it — that is what the archives will
/// occupy once every job is *done*, not what the disk must hold while the
/// backfill is *running*, and intake's own single-job warning
/// (`docs/design/disk-preflight.md` §5) and `VolumeSpace.shortfall` both check
/// against `total` for exactly that reason: the failure this exists to
/// prevent is running out of room mid-job, not mid-archive. But `total` alone
/// overstates it just as badly the other way — a backfill's jobs run
/// sequentially, and `TeardownJournal` guarantees each job's transient scratch
/// (the source download and, for `.videoWithChat`, the chat render) is torn
/// down before the next job starts, so at most one archive's transient
/// overhead exists on disk at any instant. Summing `total` across every
/// archive prices as if all of them were mid-flight at once.
///
/// So this sums what persists — `delivered`, for every archive, since none of
/// those ever get torn down — and adds only the *largest* single overshoot
/// (`total - delivered`) rather than every archive's: at the moment of peak
/// usage, one job is still mid-flight with its full transient overhead, and
/// every job before it has already been reduced to its delivered file. Taking
/// the maximum rather than assuming the longest archive is worst is one line
/// cheaper than trusting that duration alone predicts it, and stays correct
/// if a future geometry or cap ever makes overhead non-monotonic in duration.
/// An empty set costs nothing and a single archive comes out to exactly its
/// own `total`, both as a consequence of the formula rather than as cases it
/// special-cases.
///
/// This is still an instance of the "overestimate is the safe side" doctrine
/// above, not an exception to it: it is a tighter bound than `Σ total`, never
/// a looser one than `Σ delivered`.
public struct BackfillEstimate: Equatable, Sendable {

  public let count: Int
  public let duration: Duration
  public let bytes: Int64

  public init(archives: [ChannelArchive], cap: QualityCap, output: DownloadOutput) {
    count = archives.count
    duration = archives.reduce(Duration.zero) { $0 + $1.duration }

    let quality = Self.nominalQuality(for: cap)
    // Built once, outside the loop: the geometry depends only on the nominal
    // quality, which is the same for every archive here.
    let geometry = output == .videoWithChat ? CompositeGeometry(quality: quality) : nil

    var deliveredTotal = Int64(0)
    var peakOverhead = Int64(0)
    for archive in archives {
      let estimate = SpaceEstimate(quality: quality, duration: archive.duration, composite: geometry)
      deliveredTotal += estimate.delivered
      peakOverhead = max(peakOverhead, estimate.total - estimate.delivered)
    }
    bytes = deliveredTotal + peakOverhead
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
