import Foundation

/// Derives the `{streamer} - {date} - {title}` base name a job's outputs are
/// named from, and the sanitization/truncation rules shared by every output
/// (video, chat log, rendered chat video).
public enum OutputNaming {

  /// APFS caps a filename at 255 *bytes*, not characters — a title of emoji
  /// or CJK hits that cap in far fewer characters than a Latin one.
  private static let maxFilenameBytes = 255

  /// Builds the shared base name for a job's outputs from the video's own
  /// metadata.
  ///
  /// The date is the video's LOCAL date, taken from `calendar`'s time zone —
  /// a stream starting late in the evening Pacific is already tomorrow in
  /// UTC, and the day everyone thinks it happened is the local one. The
  /// calendar is a parameter (rather than reading `Calendar.current`
  /// internally) so this is testable; production passes `Calendar.current`.
  public static func baseName(streamer: String, date: Date, title: String, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = calendar.timeZone

    let dateString = formatter.string(from: date)
    let joined = "\(streamer) - \(dateString) - \(title)"
    return sanitized(joined, reservingSuffixBytes: 0)
  }

  /// Makes `raw` safe to use as a filename component.
  ///
  /// - Replaces `/` and `:` (illegal / Finder-mangled on APFS) with `-`,
  ///   rather than deleting them, so words either side don't run together.
  /// - Collapses runs of whitespace to a single space.
  /// - Truncates by appending whole **grapheme clusters** while the result
  ///   stays within `255 - reservingSuffixBytes` UTF-8 bytes. Cutting at a
  ///   raw byte offset could split a multi-byte scalar into invalid UTF-8, or
  ///   sever a ZWJ sequence (like a family emoji) into unrelated emoji, so
  ///   clusters are appended one at a time instead of the string being sliced.
  /// - `reservingSuffixBytes` lets a caller reserve room for the longest
  ///   sibling suffix up front (e.g. `" - chat.json"`), so a job's outputs
  ///   never disagree about their own shared base name.
  /// - Trims trailing whitespace, `-`, and `.` left dangling by truncation.
  /// - Falls back to `"untitled"` if nothing survives.
  public static func sanitized(_ raw: String, reservingSuffixBytes: Int) -> String {
    var working = raw.replacingOccurrences(of: "/", with: "-")
    working = working.replacingOccurrences(of: ":", with: "-")
    working = collapsingWhitespace(working)

    let budget = max(0, maxFilenameBytes - reservingSuffixBytes)
    var result = ""
    var byteCount = 0
    for cluster in working {
      let clusterBytes = String(cluster).utf8.count
      guard byteCount + clusterBytes <= budget else { break }
      result.append(cluster)
      byteCount += clusterBytes
    }

    while let last = result.last, last == " " || last == "-" || last == "." {
      result.removeLast()
    }

    return result.isEmpty ? "untitled" : result
  }

  /// Collapses any run of whitespace/newline scalars into a single space.
  private static func collapsingWhitespace(_ s: String) -> String {
    var result = ""
    var previousWasSpace = false
    for scalar in s.unicodeScalars {
      if CharacterSet.whitespacesAndNewlines.contains(scalar) {
        if !previousWasSpace {
          result.append(" ")
          previousWasSpace = true
        }
      } else {
        result.unicodeScalars.append(scalar)
        previousWasSpace = false
      }
    }
    return result
  }
}
