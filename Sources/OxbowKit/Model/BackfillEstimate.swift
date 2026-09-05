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
/// So this estimates from the *cap's* nominal resolution and the archive's
/// duration. That is honest as long as nothing presents it with intake's
/// precision, which is why every caller says "about".
///
/// **Takes archives, never a count.** The feed's own item-count field
/// overcounts the edges actually returned by up to two
/// (`docs/twitch-channel-api.md` §5.1), so `docs/design/channel-watching.md`
/// §3.3 requires the total be summed from what is in hand. There is
/// deliberately no initialiser that accepts a number.
public struct BackfillEstimate: Equatable, Sendable {

  /// The short side a cap admits, in pixels, for estimation only.
  ///
  /// `.best` is treated as 1080: it admits anything, but a Twitch broadcast
  /// above 1080 is rare enough that assuming more would overstate the common
  /// case badly, and understating the rare one is the safer error for a
  /// number someone is deciding disk space against.
  private static func nominalShortSide(_ cap: QualityCap) -> Int { cap.ceiling ?? 1080 }

  public let count: Int
  public let duration: Duration
  public let bytes: Int64

  public init(archives: [ChannelArchive], cap: QualityCap, output: DownloadOutput) {
    count = archives.count
    duration = archives.reduce(Duration.zero) { $0 + $1.duration }

    let seconds = Double(duration.components.seconds)
    guard seconds > 0 else { bytes = 0; return }

    // 16:9 at the cap's short side, at 30fps — the same shape
    // `SpaceEstimate.compositeBitsPerPixel` is calibrated against, applied to
    // a nominal frame rather than a measured one.
    let shortSide = Double(Self.nominalShortSide(cap))
    let pixelsPerSecond = shortSide * (shortSide * 16 / 9) * 30
    var bitsPerSecond = pixelsPerSecond * SpaceEstimate.compositeBitsPerPixel

    // A composite carries the chat column beside the video, and the chat
    // render itself is an intermediate that lands on the same disk.
    if output == .videoWithChat {
      bitsPerSecond += SpaceEstimate.chatRenderBitsPerSecond
    }

    bytes = Int64(bitsPerSecond * seconds / 8)
  }
}
