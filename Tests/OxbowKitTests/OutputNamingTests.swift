import Foundation
import Testing
@testable import OxbowKit

@Suite("Output naming")
struct OutputNamingTests {

  private let instant = Date(timeIntervalSince1970: 1_787_081_691) // 2026-08-18T19:34:51Z

  private func utc() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private func pacific() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
  }

  @Test func buildsStreamerDateTitle() {
    let name = OutputNaming.baseName(
      streamer: "LeighXP", date: instant, title: "FF7 rebirth discussion", calendar: utc(),
      reservingSuffixBytes: 0)
    #expect(name == "LeighXP - 2026-08-18 - FF7 rebirth discussion")
  }

  /// The spec chooses the LOCAL date: the day the streamer and viewer think it
  /// happened. A late-evening Pacific stream is already tomorrow in UTC.
  @Test func usesTheLocalDateNotUTC() {
    // 2026-08-19T03:30:00Z is still the 18th in Pacific.
    let lateNight = Date(timeIntervalSince1970: 1_787_110_200)
    let inUTC = OutputNaming.baseName(
      streamer: "S", date: lateNight, title: "t", calendar: utc(), reservingSuffixBytes: 0)
    let inPacific = OutputNaming.baseName(
      streamer: "S", date: lateNight, title: "t", calendar: pacific(), reservingSuffixBytes: 0)

    #expect(inUTC.contains("2026-08-19"))
    #expect(inPacific.contains("2026-08-18"))
  }

  /// `baseName` must pass its reservation through to `sanitized` rather than
  /// silently returning an up-to-255-byte name — otherwise the video and its
  /// " - chat.mp4" sibling can disagree about their own shared base name.
  @Test func baseNamePassesItsReservationThrough() {
    let longTitle = String(repeating: "a", count: 300)
    let suffix = " - chat.mp4"
    let name = OutputNaming.baseName(
      streamer: "S", date: instant, title: longTitle, calendar: utc(),
      reservingSuffixBytes: suffix.utf8.count)

    #expect((name + suffix).utf8.count <= 255)
  }

  @Test func replacesCharactersIllegalInAFilename() {
    let name = OutputNaming.sanitized("re/upload: part 2", reservingSuffixBytes: 0)
    #expect(!name.contains("/"))
    #expect(!name.contains(":"))
    // Replaced, not deleted — words must not run together.
    #expect(!name.contains("reupload"))
  }

  @Test func keepsEmoji() {
    let name = OutputNaming.sanitized("stream time 🎮✨", reservingSuffixBytes: 0)
    #expect(name.contains("🎮"))
  }

  /// APFS caps a filename at 255 BYTES. A title of emoji hits it in far fewer
  /// characters than a Latin one.
  @Test func truncatesToTheByteCapNotTheCharacterCount() {
    let long = String(repeating: "🎮", count: 300)
    let name = OutputNaming.sanitized(long, reservingSuffixBytes: 0)
    #expect(name.utf8.count <= 255)
  }

  /// Cutting at a byte offset can split a scalar and produce invalid UTF-8, or
  /// sever a ZWJ sequence into unrelated emoji.
  ///
  /// A scalar-boundary truncation of this input yields 250 bytes of whole
  /// families plus one lone leading scalar of the 251st (e.g. a bare 👨) —
  /// that's still valid UTF-8 with no replacement character, so the two
  /// checks above pass even with the ZWJ sequence severed. The
  /// `allSatisfy` check below is what actually catches it: a severed
  /// scalar is a `Character` that isn't the whole family emoji.
  @Test func truncationNeverSplitsAGraphemeCluster() {
    let familyCluster: Character = "👨‍👩‍👧‍👦" // one grapheme cluster, 7 scalars, 25 UTF-8 bytes
    let family = String(repeating: familyCluster, count: 40) // ZWJ sequences
    let name = OutputNaming.sanitized(family, reservingSuffixBytes: 0)

    #expect(!name.isEmpty)
    #expect(name.utf8.count <= 255)
    // Every retained cluster is whole: re-encoding round-trips exactly.
    #expect(String(decoding: Array(name.utf8), as: UTF8.self) == name)
    #expect(!name.unicodeScalars.contains { $0 == "\u{FFFD}" })
    // Every retained Character is the whole family emoji, not a fragment.
    #expect(name.allSatisfy { $0 == familyCluster })
  }

  /// A job's video and its " - chat.mp4" sibling must not disagree about their
  /// own base name, so the longest suffix is reserved up front.
  @Test func reservesRoomForTheLongestSuffix() {
    let long = String(repeating: "a", count: 300)
    let reserved = " - chat.json".utf8.count
    let name = OutputNaming.sanitized(long, reservingSuffixBytes: reserved)

    #expect(name.utf8.count + reserved <= 255)
  }

  @Test func trimsSeparatorsLeftDanglingByTruncation() {
    let name = OutputNaming.sanitized("title - ", reservingSuffixBytes: 0)
    #expect(!name.hasSuffix(" "))
    #expect(!name.hasSuffix("-"))
  }

  /// A leading `.` or `-` is trimmed too — not just trailing — so a title
  /// can never silently turn its output into a Finder-hidden dotfile.
  @Test func trimsLeadingSeparatorsSoTheResultIsNeverHidden() {
    let dotted = OutputNaming.sanitized(".hidden title", reservingSuffixBytes: 0)
    #expect(!dotted.hasPrefix("."))

    let dashed = OutputNaming.sanitized("- dashed title", reservingSuffixBytes: 0)
    #expect(!dashed.hasPrefix("-"))
  }

  @Test func neverReturnsAnEmptyName() {
    #expect(!OutputNaming.sanitized("", reservingSuffixBytes: 0).isEmpty)
    #expect(!OutputNaming.sanitized("///", reservingSuffixBytes: 0).isEmpty)
  }

  /// NUL in particular truncates a path at the C string boundary once it
  /// reaches `FileManager` or argv, so control characters must not survive.
  @Test func stripsControlCharacters() {
    let name = OutputNaming.sanitized("bad\u{0}name\u{7}", reservingSuffixBytes: 0)
    #expect(name == "badname")
    #expect(!name.unicodeScalars.contains { $0 == "\u{0}" })
    #expect(!name.unicodeScalars.contains { $0 == "\u{7}" })
  }

  @Test func whitespaceOnlyTitleFallsBackToUntitled() {
    #expect(OutputNaming.sanitized("   ", reservingSuffixBytes: 0) == "untitled")
  }

  @Test func collapsesANewlineInsideATitle() {
    let name = OutputNaming.sanitized("line one\nline two", reservingSuffixBytes: 0)
    #expect(name == "line one line two")
  }

  @Test func fallsBackToUntitledWhenTheReservationExceedsTheBudget() {
    #expect(OutputNaming.sanitized("hello", reservingSuffixBytes: 1000) == "untitled")
  }

  /// A single grapheme cluster that is itself bigger than what's left of the
  /// budget must be dropped whole, not split to fit.
  @Test func fallsBackToUntitledWhenASingleGraphemeExceedsTheBudget() {
    let familyCluster = "👨‍👩‍👧‍👦" // 25 UTF-8 bytes, one grapheme cluster
    let reserved = 255 - (familyCluster.utf8.count - 1) // leaves a 24-byte budget
    #expect(OutputNaming.sanitized(familyCluster, reservingSuffixBytes: reserved) == "untitled")
  }
}
