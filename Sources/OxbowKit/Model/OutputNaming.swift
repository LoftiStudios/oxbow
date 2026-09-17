import Foundation

/// Derives the `{streamer} - {date} - {title}` base name a job's outputs are
/// named from, and the sanitization/truncation rules shared by every output
/// (video, chat log, rendered chat video).
public enum OutputNaming {

  /// APFS caps a filename at 255 *bytes*, not characters — a title of emoji
  /// or CJK hits that cap in far fewer characters than a Latin one.
  private static let maxFilenameBytes = 255

  /// Builds a shared output name using the video's date in `calendar`'s time zone. Reserve the
  /// longest sibling suffix in UTF-8 bytes so all outputs can share the base within APFS's
  /// 255-byte limit.
  public static func baseName(
    streamer: String, date: Date, title: String, calendar: Calendar, reservingSuffixBytes: Int
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = calendar.timeZone

    let dateString = formatter.string(from: date)
    let joined = "\(streamer) - \(dateString) - \(title)"
    return sanitized(joined, reservingSuffixBytes: reservingSuffixBytes)
  }

  /// Sanitizes a filename: replaces `/` and `:` with `-`, strips controls, collapses
  /// whitespace, and truncates at whole grapheme clusters within `255 - reservingSuffixBytes`
  /// UTF-8 bytes. Trims surrounding whitespace, dots and hyphens; falls back to `untitled` if
  /// empty. Reserve the longest sibling suffix to keep shared base names consistent.
  public static func sanitized(_ raw: String, reservingSuffixBytes: Int) -> String {
    var working = raw.replacingOccurrences(of: "/", with: "-")
    working = working.replacingOccurrences(of: ":", with: "-")
    working = strippingControlCharactersAndCollapsingWhitespace(working)

    let budget = max(0, maxFilenameBytes - reservingSuffixBytes)
    var result = ""
    var byteCount = 0
    for cluster in working {
      let clusterBytes = String(cluster).utf8.count
      guard byteCount + clusterBytes <= budget else { break }
      result.append(cluster)
      byteCount += clusterBytes
    }

    while let first = result.first, first == " " || first == "-" || first == "." {
      result.removeFirst()
    }
    while let last = result.last, last == " " || last == "-" || last == "." {
      result.removeLast()
    }

    return result.isEmpty ? "untitled" : result
  }

  /// Returns the first unused name: `name.mp4`, `name (2).mp4`, etc. Reserves counter bytes by
  /// shortening the base so the result stays within 255 UTF-8 bytes. Delivery handles races
  /// after this check.
  public static func availableURL(for destination: URL, exists: (URL) -> Bool) -> URL {
    guard exists(destination) else { return destination }

    let directory = destination.deletingLastPathComponent()
    let pathExtension = destination.pathExtension
    // Not `appendingPathExtension`: an empty extension would leave a
    // trailing "." and invent a file type the caller never asked for.
    let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
    let base = destination.deletingPathExtension().lastPathComponent

    var counter = 2
    while true {
      let marker = " (\(counter))"
      let trimmed = sanitized(base, reservingSuffixBytes: (marker + suffix).utf8.count)
      let candidate = directory.appending(path: trimmed + marker + suffix)
      if !exists(candidate) { return candidate }
      counter += 1
    }
  }

  /// Drops only single-scalar Unicode Cc controls and collapses whitespace. Do not filter
  /// scalars with `CharacterSet.controlCharacters`: it also includes format characters such as
  /// ZWJ and would break emoji clusters.
  private static func strippingControlCharactersAndCollapsingWhitespace(_ s: String) -> String {
    var result = ""
    var previousWasSpace = false
    for character in s {
      if character.isWhitespace {
        if !previousWasSpace {
          result.append(" ")
          previousWasSpace = true
        }
        continue
      }
      if character.unicodeScalars.count == 1,
         character.unicodeScalars[character.unicodeScalars.startIndex].properties.generalCategory == .control
      {
        continue
      }
      result.append(character)
      previousWasSpace = false
    }
    return result
  }
}
