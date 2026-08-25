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
  ///
  /// `reservingSuffixBytes` is required, not defaulted, so a caller cannot
  /// get an unreserved (up to 255-byte) name by omission: a job's video and
  /// its ` - chat.mp4` sibling must agree on one shared base name, which
  /// only holds if every caller reserves room for the longest suffix it
  /// will append. Pass the byte length of the longest suffix any of this
  /// job's outputs will use.
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

  /// Makes `raw` safe to use as a filename component.
  ///
  /// - Replaces `/` and `:` (illegal / Finder-mangled on APFS) with `-`,
  ///   rather than deleting them, so words either side don't run together.
  /// - Strips other control characters (e.g. NUL, BEL) outright — titles are
  ///   streamer-authored, and a NUL in particular truncates a path at the C
  ///   string boundary when it reaches `FileManager` or argv.
  /// - Collapses runs of whitespace (including newlines) to a single space.
  /// - Truncates by appending whole **grapheme clusters** while the result
  ///   stays within `255 - reservingSuffixBytes` UTF-8 bytes. Cutting at a
  ///   raw byte offset could split a multi-byte scalar into invalid UTF-8, or
  ///   sever a ZWJ sequence (like a family emoji) into unrelated emoji, so
  ///   clusters are appended one at a time instead of the string being sliced.
  /// - `reservingSuffixBytes` lets a caller reserve room for the longest
  ///   sibling suffix up front (e.g. `" - chat.json"`), so a job's outputs
  ///   never disagree about their own shared base name.
  /// - Trims leading and trailing whitespace, `-`, and `.` left dangling by
  ///   truncation — a leading `.` or `-` is stripped too, so a title cannot
  ///   silently turn its output into a Finder-hidden dotfile.
  /// - Falls back to `"untitled"` if nothing survives.
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

  /// Strips control characters (NUL, BEL, and the like) outright, and
  /// collapses any run of whitespace/newline characters into a single space.
  ///
  /// This walks `Character`s (grapheme clusters), not `Unicode.Scalar`s, and
  /// only ever drops a *single-scalar* character whose general category is
  /// `.control` (Unicode Cc). That distinction matters:
  /// `CharacterSet.controlCharacters` covers Cc *and* Cf (format characters)
  /// — which includes ZERO WIDTH JOINER. Filtering scalar-by-scalar against
  /// that set would strip the ZWJ out of a family emoji and sever it into
  /// unrelated emoji, the exact hazard this file exists to avoid. Walking
  /// whole clusters and checking only true single-scalar Cc control codes
  /// means a multi-scalar cluster (a ZWJ sequence, a flag, a
  /// variation-selected character) is never inspected scalar-by-scalar and
  /// so can never be partially stripped.
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
