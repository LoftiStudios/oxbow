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
      streamer: "LeighXP", date: instant, title: "FF7 rebirth discussion", calendar: utc())
    #expect(name == "LeighXP - 2026-08-18 - FF7 rebirth discussion")
  }

  /// The spec chooses the LOCAL date: the day the streamer and viewer think it
  /// happened. A late-evening Pacific stream is already tomorrow in UTC.
  @Test func usesTheLocalDateNotUTC() {
    // 2026-08-19T03:30:00Z is still the 18th in Pacific.
    let lateNight = Date(timeIntervalSince1970: 1_787_110_200)
    let inUTC = OutputNaming.baseName(streamer: "S", date: lateNight, title: "t", calendar: utc())
    let inPacific = OutputNaming.baseName(streamer: "S", date: lateNight, title: "t", calendar: pacific())

    #expect(inUTC.contains("2026-08-19"))
    #expect(inPacific.contains("2026-08-18"))
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
  @Test func truncationNeverSplitsAGraphemeCluster() {
    let family = String(repeating: "👨‍👩‍👧‍👦", count: 40) // ZWJ sequences
    let name = OutputNaming.sanitized(family, reservingSuffixBytes: 0)

    #expect(name.utf8.count <= 255)
    // Every retained cluster is whole: re-encoding round-trips exactly.
    #expect(String(decoding: Array(name.utf8), as: UTF8.self) == name)
    #expect(!name.unicodeScalars.contains { $0 == "\u{FFFD}" })
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

  @Test func neverReturnsAnEmptyName() {
    #expect(!OutputNaming.sanitized("", reservingSuffixBytes: 0).isEmpty)
    #expect(!OutputNaming.sanitized("///", reservingSuffixBytes: 0).isEmpty)
  }
}
