import Foundation
import Testing

@testable import OxbowKit

@Suite("Chat timeline")
struct ChatTimelineTests {

  /// A chat file with one comment per `(offset, createdAt)` pair. `createdAt` is seconds after
  /// an arbitrary epoch, written with millisecond precision as Twitch writes it.
  private func document(
    start: Double = 0, end: Double = 60, comments: [(offset: Double, createdAt: Double)]) throws
    -> ChatDocument
  {
    let base = Date(timeIntervalSince1970: 1_756_000_000)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let entries = comments.enumerated().map { index, comment in
      let created = formatter.string(from: base.addingTimeInterval(comment.createdAt))
      return """
        {"_id": "\(index)", "created_at": "\(created)", "content_offset_seconds": \(comment.offset),
         "commenter": {"display_name": "u\(index)", "name": "u\(index)"},
         "message": {"body": "m", "fragments": [{"text": "m", "emoticon": null}], "user_color": null}}
        """
    }
    let json = """
      {"video": {"start": \(start), "end": \(end)}, "comments": [\(entries.joined(separator: ","))]}
      """
    return try ChatDocument.decode(from: Data(json.utf8))
  }

  @Test func redrawsEverySixFramesAtThirtyFramesPerSecond() throws {
    let timeline = ChatTimeline(document: try document(comments: []), framerate: 30)
    #expect(timeline.updateFrame == 6)
    #expect(timeline.updateTime(forFrame: 0) == 0)
    #expect(timeline.updateTime(forFrame: 5) == 0)
    #expect(timeline.updateTime(forFrame: 6) == 0.2)
  }

  /// Ticks are absolute VOD time, so a trimmed file's frame 0 is at its start, floored to a
  /// second, and the render runs to the ceiling of its end.
  @Test func framesCountFromTheFlooredStartToTheCeilingOfTheEnd() throws {
    let timeline = ChatTimeline(
      document: try document(start: 9000.5, end: 9180.01, comments: []), framerate: 30)
    #expect(timeline.startTick == 270_000)
    #expect(timeline.frameCount == 275_401 - 270_000)
    #expect(timeline.updateTime(forFrame: 0) == 9000)
  }

  /// The CLI's own rounding, kept on purpose: 0.65 floors to grid step 3, and `3 * 0.2` is
  /// 0.6000000000000001 — later than the redraw at 18/30.0 — so the comment first shows a
  /// redraw late, at frame 24.
  @Test func keepsTheCLIsFloatingPointLateness() throws {
    let timeline = ChatTimeline(
      document: try document(comments: [(0.65, 0)]), framerate: 30, disperses: false)
    #expect(timeline.offsets == [0.6000000000000001])
    #expect(timeline.newestIndex(at: timeline.updateTime(forFrame: 18)) == -1)
    #expect(timeline.newestIndex(at: timeline.updateTime(forFrame: 24)) == 0)
  }

  /// And the reverse, easy to get wrong the other way: 0.6 itself divides to
  /// 2.9999999999999996 and floors down a whole step, to 0.4.
  @Test func anOffsetOfPointSixFloorsDownAStep() throws {
    let timeline = ChatTimeline(
      document: try document(comments: [(0.6, 0)]), framerate: 30, disperses: false)
    #expect(timeline.offsets == [0.4])
  }

  @Test func aCommentDueExactlyNowIsShown() throws {
    let timeline = ChatTimeline(
      document: try document(comments: [(1, 0), (2, 0)]), framerate: 30, disperses: false)
    #expect(timeline.newestIndex(at: 0.99) == -1)
    #expect(timeline.newestIndex(at: 1) == 0)
    #expect(timeline.newestIndex(at: 2) == 1)
  }

  /// A comment waits for every comment before it in the list, whatever its own offset.
  @Test func aLaterIndexWaitsForEveryEarlierOne() throws {
    let timeline = ChatTimeline(
      document: try document(comments: [(1, 0), (5, 0), (2, 0)]), framerate: 30, disperses: false)
    #expect(timeline.newestIndex(at: 3) == 0)
    #expect(timeline.newestIndex(at: 5) == 2)
  }

  /// Consistent created_at: each offset becomes its created_at minus the earliest estimate,
  /// which only ever moves it later.
  @Test func disperseFromCreatedAtWhenTheClockIsConsistent() throws {
    let timeline = ChatTimeline(
      document: try document(comments: [(10, 10.0), (10, 10.4), (11, 11.7)]),
      framerate: 30, updateRate: 0)
    #expect(timeline.offsets.map { ($0 * 1000).rounded() / 1000 } == [10, 10.4, 11.7])
  }

  /// Inconsistent created_at: seeded jitter. As coded — not as its doc comment says — the
  /// first two of a run stay on the second and the rest spread across it in order.
  @Test func disperseByJitterWhenTheClockIsNot() throws {
    let timeline = ChatTimeline(
      document: try document(comments: [(1, 0), (2, 0), (2, 0), (2, 0), (2, 0), (3, 10)]),
      framerate: 30, updateRate: 0)
    let offsets = timeline.offsets
    #expect(offsets[0] == 1)
    #expect(offsets[1] == 2)
    #expect(offsets[2] == 2)
    #expect(offsets[3] > 2 && offsets[3] < offsets[4] && offsets[4] < 3)
    #expect(offsets[5] == 3)
  }

  @Test func aFractionalOffsetDisablesDispersionEntirely() throws {
    let timeline = ChatTimeline(
      document: try document(comments: [(1.5, 0), (2, 5), (2, 5), (2, 5)]),
      framerate: 30, updateRate: 0)
    #expect(timeline.offsets == [1.5, 2, 2, 2])
  }
}
