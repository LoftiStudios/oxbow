import Foundation
import Testing
@testable import OxbowKit

@Suite("Source fingerprint")
struct SourceFingerprintTests {

  private func tempFile(bytes: Int) throws -> URL {
    let url = URL(filePath: NSTemporaryDirectory())
      .appending(path: "src-\(UUID().uuidString).bin")
    try Data(repeating: 0x7, count: bytes).write(to: url)
    return url
  }

  @Test func roundTripsThroughDisk() throws {
    let file = try tempFile(bytes: 128)
    defer { try? FileManager.default.removeItem(at: file) }
    let record = URL(filePath: NSTemporaryDirectory())
      .appending(path: "fp-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: record) }

    let original = try SourceFingerprint.of(file, duration: .seconds(547))
    try original.write(to: record)

    #expect(try SourceFingerprint.read(from: record) == original)
  }

  @Test func matchesAnIdenticalSource() throws {
    let file = try tempFile(bytes: 128)
    defer { try? FileManager.default.removeItem(at: file) }

    let first = try SourceFingerprint.of(file, duration: .seconds(547))
    let second = try SourceFingerprint.of(file, duration: .seconds(547))

    #expect(first.matches(second))
  }

  /// Twitch mutes VOD sections for DMCA after the fact, which re-encodes
  /// audio and changes the file. Half a video from before the mute and half
  /// from after is exactly the failure nobody notices — so it refuses rather
  /// than repairs. docs/design/resume.md §7.
  @Test func refusesAChangedSource() throws {
    let before = try tempFile(bytes: 128)
    let after = try tempFile(bytes: 129)
    defer { for f in [before, after] { try? FileManager.default.removeItem(at: f) } }

    let recorded = try SourceFingerprint.of(before, duration: .seconds(547))
    let fresh = try SourceFingerprint.of(after, duration: .seconds(547))

    #expect(!recorded.matches(fresh))
  }

  @Test func refusesAChangedDuration() throws {
    let file = try tempFile(bytes: 128)
    defer { try? FileManager.default.removeItem(at: file) }

    #expect(!(try SourceFingerprint.of(file, duration: .seconds(547))
      .matches(try SourceFingerprint.of(file, duration: .seconds(500)))))
  }
}
