import Foundation

/// Extract a VOD id or clip slug; reject lookalike hosts such as twitch.tv.evil.com.
nonisolated enum TwitchLink {

  enum Target: Equatable {
    case video(String)
    case clip(String)
  }

  static func parse(_ text: String) -> Target? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Bare digits identify a VOD; other undotted tokens are clip slugs. Reject dotted tokens as
    // unrecognized hosts.
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
