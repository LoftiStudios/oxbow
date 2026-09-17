import Foundation

/// Requests larger VOD frames using an undocumented CDN size token. Callers must fall back to
/// the original URL if loading fails. Match `thumbN-WxH.jpg` only: clips use `thumb-…-WxH.jpg`
/// and must remain unchanged. See `docs/twitch-metadata.md` §8.
public enum StreamThumbnail {
  /// 1280x720 leaves room for a resized Retina preview; four frames total roughly 430 KB per
  /// VOD.
  public static let targetWidth = 1280
  public static let targetHeight = 720

  /// Rewrites a VOD frame's size token; returns other URLs unchanged.
  public static func rewritten(_ url: URL) -> URL {
    // Compile locally because `Regex` is not Sendable. Digits immediately after `thumb`
    // distinguish VOD frames from clip thumbnails.
    let vodFramePattern = /(thumb\d+)-\d+x\d+(\.jpg)$/

    let text = url.absoluteString
    guard let match = text.firstMatch(of: vodFramePattern) else { return url }
    let (prefix, suffix) = (match.output.1, match.output.2)
    let replacement = "\(prefix)-\(targetWidth)x\(targetHeight)\(suffix)"
    let rewritten = text.replacingCharacters(in: match.range, with: replacement)
    return URL(string: rewritten) ?? url
  }
}
