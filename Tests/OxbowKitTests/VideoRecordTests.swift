import Foundation
import Testing
@testable import OxbowKit

@Suite("Video record")
struct VideoRecordTests {

  /// What a sweep knows.
  private var swept: VideoRecord {
    VideoRecord(
      id: "2844787557",
      login: "wheelyf",
      title: "day 46",
      durationSeconds: 10203,
      publishedAt: Date(timeIntervalSince1970: 1_757_000_000),
      categoryName: "ELDEN RING",
      thumbnailURLs: [URL(string: "https://cdn/a.jpg")!],
      lastSeenOnTwitch: Date(timeIntervalSince1970: 1_757_100_000))
  }

  /// What a submission knows. Note the four frames and the absent
  /// `lastSeenOnTwitch`.
  private var submitted: VideoRecord {
    VideoRecord(
      id: "2844787557",
      login: "wheelyf",
      title: "day 46",
      durationSeconds: 10203,
      publishedAt: Date(timeIntervalSince1970: 1_757_000_000),
      qualities: [StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_000_000)],
      thumbnailURLs: [
        URL(string: "https://cdn/a.jpg")!, URL(string: "https://cdn/b.jpg")!,
        URL(string: "https://cdn/c.jpg")!, URL(string: "https://cdn/d.jpg")!,
      ],
      payloadHelperVersion: "1.56.5")
  }

  /// The rule the whole stage turns on: neither source is complete, and a
  /// later write must not erase what an earlier one learned.
  @Test("merging keeps what each side knows and erases nothing")
  func mergeIsAdditive() {
    let merged = swept.merging(submitted)

    #expect(merged.lastSeenOnTwitch == swept.lastSeenOnTwitch)  // only the sweep had it
    #expect(merged.qualities.count == 1)                        // only the submission had it
    #expect(merged.categoryName == "ELDEN RING")                // only the sweep had it
    #expect(merged.payloadHelperVersion == "1.56.5")
    #expect(merged.thumbnailURLs.count == 4)                    // the richer set wins
  }

  /// And in the other order, because the sweep can run after a submission.
  @Test("merging is order-independent for absent fields")
  func mergeBothWays() {
    let forward = swept.merging(submitted)
    let backward = submitted.merging(swept)

    #expect(forward.qualities.count == backward.qualities.count)
    #expect(forward.categoryName == backward.categoryName)
    #expect(forward.lastSeenOnTwitch == backward.lastSeenOnTwitch)
    #expect(forward.thumbnailURLs.count == backward.thumbnailURLs.count)
  }

  /// `lastSeenOnTwitch` is the one field where newer genuinely wins — it is a
  /// timestamp of the most recent sighting, not a fact about the video.
  @Test("a newer sighting replaces an older one")
  func newerSightingWins() {
    let old = Date(timeIntervalSince1970: 1_000)
    let new = Date(timeIntervalSince1970: 2_000)
    var a = swept; a.lastSeenOnTwitch = old
    var b = swept; b.lastSeenOnTwitch = new

    #expect(a.merging(b).lastSeenOnTwitch == new)
    #expect(b.merging(a).lastSeenOnTwitch == new)
  }

  /// A delivered file is a fact about the disk. An incoming record that does
  /// not mention one must not clear it.
  @Test("a merge never clears a delivered path")
  func deliveredPathSurvives() {
    var downloaded = swept
    downloaded.deliveredPath = "/Volumes/Helios/wheelyf/day46.mp4"

    #expect(downloaded.merging(swept).deliveredPath == "/Volumes/Helios/wheelyf/day46.mp4")
  }

  /// Merging two records for different videos is a programmer error, not a
  /// runtime condition — but it must not silently produce a chimera.
  @Test("merging a different id keeps the receiver untouched")
  func mismatchedIDIsIgnored() {
    var other = submitted
    other.id = "999"

    #expect(swept.merging(other) == swept)
  }

  @Test("a record round-trips through JSON")
  func codableRoundTrip() throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let data = try encoder.encode(submitted)
    #expect(try decoder.decode(VideoRecord.self, from: data) == submitted)
  }

  /// The point of keeping any of this: an expired video still renders.
  @Test("a record can still describe a video Twitch has dropped")
  func rememberedRendersAnExpiredVideo() {
    let info = submitted.remembered()
    #expect(info?.title == "day 46")
    #expect(info?.login == "wheelyf")
    #expect(info?.duration == .seconds(10203))
    #expect(info?.thumbnailURLs.count == 4)
    #expect(info?.qualities.first?.name == "1080p60")
  }

  /// A row migrated from the old bare-id seen-set has no title and never
  /// will, so there is nothing to render and it says so rather than
  /// producing a card named after nobody.
  @Test("a record with no title remembers nothing")
  func rememberedNeedsATitle() {
    #expect(VideoRecord(id: "1", login: "wheelyf").remembered() == nil)
  }

  /// The fallback, for a record written before `displayName` existed or by a
  /// path that never learned one. The login is what it can honestly offer.
  @Test("the streamer falls back to the login when no display name was kept")
  func rememberedUsesTheLogin() {
    #expect(submitted.remembered()?.streamer == "wheelyf")
  }

  /// **And prefers the display name when there is one.**
  ///
  /// `video-record.md` §3.4: a display name and a login are two different
  /// strings and neither follows from the other. Without this the remembered
  /// card read `seecatplay` where the live one read `SeeCatPlay` — a visible
  /// difference between a card the record drew and the same card drawn from
  /// Twitch, which §4.1 says must not exist.
  @Test("the streamer prefers the stored display name")
  func rememberedPrefersTheDisplayName() {
    var record = submitted
    record.displayName = "WheelyF"
    #expect(record.remembered()?.streamer == "WheelyF")
  }

  /// Additive like every other field: a writer that never learned the display
  /// name must not erase one another writer did.
  @Test("merging keeps a display name the incoming record lacks")
  func mergingKeepsTheDisplayName() {
    var kept = submitted
    kept.displayName = "WheelyF"
    let incoming = VideoRecord(id: kept.id, deliveredPath: "/x.mp4")
    #expect(kept.merging(incoming).displayName == "WheelyF")
  }

}
