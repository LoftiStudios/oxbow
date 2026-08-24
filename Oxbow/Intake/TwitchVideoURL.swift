import Foundation

/// Recovers a VOD id from whatever the user pasted.
///
/// Deliberately strict: a clip or channel URL is rejected rather than
/// coerced, because silently downloading the wrong thing is worse than
/// telling the user the address is not a VOD.
///
/// `nonisolated`: the target defaults new declarations to `@MainActor`, but
/// this is pure string parsing with no UI dependency, and Task 7's intake
/// sheet should be free to call it off the main actor too.
nonisolated enum TwitchVideoURL {

  /// The id, or nil if `text` does not name a VOD.
  static func videoID(from text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if isNumeric(trimmed) { return trimmed }

    // Percent-decoding and query stripping come free with URLComponents, but
    // it needs a scheme to populate `path`, so supply one when absent.
    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard
      let components = URLComponents(string: candidate),
      let host = components.host,
      host == "twitch.tv" || host.hasSuffix(".twitch.tv")
    else { return nil }

    let segments = components.path.split(separator: "/").map(String.init)
    guard segments.count == 2, segments[0] == "videos", isNumeric(segments[1]) else { return nil }
    return segments[1]
  }

  private static func isNumeric(_ value: String) -> Bool {
    !value.isEmpty && value.allSatisfy(\.isNumber)
  }
}
