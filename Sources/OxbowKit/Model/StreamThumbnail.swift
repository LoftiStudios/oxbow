import Foundation

/// Rewrites a VOD preview frame's URL to ask the CDN for a larger size than
/// Twitch's own GraphQL query offers — and leaves anything that is not
/// shaped like a VOD frame alone.
///
/// **This is undocumented CDN behaviour, not a Twitch contract.** Measured
/// against the live CDN on VOD 2859050150, 2026-09-01: a VOD frame's path is
/// `…/thumb/thumb0-320x180.jpg`, and `320x180` there is a size token, not a
/// fixed asset — the same frame returned HTTP 200 at 640x360 (38 KB),
/// 1280x720 (108 KB) and 1920x1080 (176 KB). The Twitch web client depends on
/// this same path shape, so it is unlikely to disappear, but nothing here
/// guarantees it will keep working. Every caller of ``rewritten(_:)`` must
/// treat its result as a request, not a promise, and fall back to the
/// original URL Twitch actually gave us if the rewritten one 404s.
///
/// **A clip's preview is a different shape and must not be touched.** A
/// clip's `thumbnailURL` looks like
/// `…/landscape/thumb/thumb-0000000000-1920x1080.jpg` — already full size,
/// and from a single asset rather than a sampled list. Rewriting it would be
/// pointless at best (it already is the size this asks for) and would ask
/// the CDN for a variant that may not exist at worst. Both URLs end in
/// `-WxH.jpg`, so the match has to key on the part that differs: a VOD
/// frame's filename is `thumbN-WxH.jpg` (digits directly after `thumb`,
/// no dash), a clip's is `thumb-0000000000-WxH.jpg` (a dash directly after
/// `thumb`). Only the first shape is rewritten.
public enum StreamThumbnail {
  /// The size requested in place of whatever token the URL already carries.
  ///
  /// 1280x720: the card draws the thumbnail at roughly 490 physical pixels
  /// on a 2x display today, and the intake window resizes, so 1280 leaves
  /// headroom for a wider window without paying for the 1920 variant's
  /// 176 KB. Four frames at 1280x720 is roughly 430 KB per VOD, fetched
  /// once and CDN-cached after that.
  public static let targetWidth = 1280
  public static let targetHeight = 720

  /// `url` with its size token rewritten to `targetWidth`x`targetHeight`, or
  /// `url` unchanged if it does not look like a VOD frame.
  ///
  /// Pure and total: never throws, never returns nil. A URL this cannot
  /// parse as a rewrite candidate — a clip's full-size thumbnail, or
  /// anything else entirely — passes straight through, which is the
  /// documented behaviour for "leave it alone," not a failure case.
  public static func rewritten(_ url: URL) -> URL {
    // Built fresh per call rather than cached in a `static let`: a compiled
    // `Regex` is not `Sendable`, so a stored global would need its own
    // isolation for no real benefit — this pattern is small and rewriting a
    // handful of URLs per fetched video is not a hot path.
    //
    // Matches a VOD frame's filename specifically: `thumb`, one or more
    // digits (the frame index), a dash, the existing size token, `.jpg`.
    // Captured in two groups so the replacement can keep the `thumbN` prefix
    // and the `.jpg` suffix and only swap what sits between them.
    //
    // A clip's `thumb-0000000000-WxH.jpg` never matches: the character right
    // after `thumb` is a dash, not a digit, so `\d+` fails to start there at
    // all — the whole pattern fails on that filename rather than matching a
    // wrong substring of it.
    let vodFramePattern = /(thumb\d+)-\d+x\d+(\.jpg)$/

    let text = url.absoluteString
    guard let match = text.firstMatch(of: vodFramePattern) else { return url }
    let (prefix, suffix) = (match.output.1, match.output.2)
    let replacement = "\(prefix)-\(targetWidth)x\(targetHeight)\(suffix)"
    let rewritten = text.replacingCharacters(in: match.range, with: replacement)
    // `URL(string:)` only fails here if the rewrite somehow produced an
    // invalid URL, which the fixed replacement template cannot do against an
    // already-valid `url`'s text — defensive, not expected to trigger.
    return URL(string: rewritten) ?? url
  }
}
