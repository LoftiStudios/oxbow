import Foundation

/// Recovers a VOD id or a clip slug from whatever the user pasted.
///
/// Deliberately strict about the host: `twitch.tv.evil.com` and
/// `evil-twitch.tv` are both rejected, because silently downloading from
/// somewhere else is worse than saying the address is not understood.
nonisolated enum TwitchLink {

  enum Target: Equatable {
    case video(String)
    case clip(String)
  }

  static func parse(_ text: String) -> Target? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // A bare token: all digits is a VOD id, anything else a clip slug — but
    // only if it has no dot. Clip slugs are Twitch-generated alphanumeric
    // words with no punctuation; a dotted bare token (e.g. "evil-twitch.tv")
    // is a host someone typed without a scheme, not a slug, and letting it
    // through here would silently hand the CLI a nonsense id instead of
    // giving the user an honest rejection.
    if !trimmed.contains("/") && !trimmed.contains(":") {
      guard !trimmed.contains(".") else { return nil }
      return isNumeric(trimmed) ? .video(trimmed) : .clip(trimmed)
    }

    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard
      let components = URLComponents(string: candidate),
      let host = components.host,
      host == "twitch.tv" || host.hasSuffix(".twitch.tv")
    else { return nil }

    let segments = components.path.split(separator: "/").map(String.init)

    // clips.twitch.tv/<slug>
    if host == "clips.twitch.tv", segments.count == 1, !segments[0].isEmpty {
      return .clip(segments[0])
    }
    // twitch.tv/videos/<id>
    if segments.count == 2, segments[0] == "videos", isNumeric(segments[1]) {
      return .video(segments[1])
    }
    // twitch.tv/<channel>/clip/<slug>
    if segments.count == 3, segments[1] == "clip", !segments[2].isEmpty {
      return .clip(segments[2])
    }
    return nil
  }

  private static func isNumeric(_ value: String) -> Bool {
    !value.isEmpty && value.allSatisfy(\.isNumber)
  }
}
