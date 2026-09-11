import Foundation
import Testing
import OxbowKit
@testable import Oxbow

/// `InspectorSubject.resolve` — the whole behavioural surface of the
/// inspector, exercised without building a view.
///
/// `docs/design/inspector.md` §3.3. A `static` over plain values for the same
/// reason `WatchingModel.listings(from:)` and `ChannelCard
/// .disconnectedVolume(in:)` are: no store, no sweep, no window.
@MainActor
@Suite("Inspector subject")
struct InspectorSubjectTests {

  private func step(_ kind: StepKind, _ status: StepStatus = .queued) -> Step {
    Step(id: StepID(rawValue: UUID()), kind: kind, status: status)
  }

  /// A job whose one step is a video download, so `mediaIdentifier` answers.
  private func videoJob(
    _ title: String, videoID: String, _ status: StepStatus = .queued
  ) -> Job {
    Job(
      id: JobID(rawValue: UUID()), created: Date(timeIntervalSince1970: 0),
      title: title,
      steps: [step(.downloadVideo(VideoRequest(
        videoID: videoID, quality: "360p30",
        destination: URL(filePath: "/out/\(title).mp4"))), status)])
  }

  /// A job carrying no video or clip request at all, so `mediaIdentifier` is
  /// nil — `video-record.md` §4.2's case that must stay addressable.
  private func chatOnlyJob(_ title: String) -> Job {
    Job(
      id: JobID(rawValue: UUID()), created: Date(timeIntervalSince1970: 0),
      title: title,
      steps: [step(.downloadChat(ChatRequest(videoID: "1", format: .json)))])
  }

  @Test func nothingSelectedIsNothing() {
    #expect(InspectorSubject.resolve(
      destination: .queue, queueSelection: [], watchingSelection: nil,
      sections: [], library: VideoLibrary(), jobs: []) == .nothing)
  }

  @Test func oneQueueJobWithAVideoResolvesToThatVideo() {
    let j = videoJob("A", videoID: "123")
    #expect(InspectorSubject.resolve(
      destination: .queue, queueSelection: [j.id], watchingSelection: nil,
      sections: [], library: VideoLibrary(), jobs: [j])
      == .one(.video("123")))
  }

  /// `video-record.md` §4.2: a job with no resolvable video id stays
  /// addressable, keyed by its `JobID` instead of becoming un-openable.
  @Test func oneQueueJobWithoutAVideoResolvesToTheJob() {
    let j = chatOnlyJob("A")
    #expect(InspectorSubject.resolve(
      destination: .queue, queueSelection: [j.id], watchingSelection: nil,
      sections: [], library: VideoLibrary(), jobs: [j])
      == .one(.job(j.id)))
  }

  @Test func aSelectedIdThatMatchesNoJobIsNothing() {
    let j = videoJob("A", videoID: "123")
    #expect(InspectorSubject.resolve(
      destination: .queue, queueSelection: [JobID(rawValue: UUID())],
      watchingSelection: nil, sections: [], library: VideoLibrary(), jobs: [j])
      == .nothing)
  }

  @Test func severalSelectedCountsThemByStatus() {
    let a = videoJob("A", videoID: "1", .queued)
    let b = videoJob("B", videoID: "2", .queued)
    let c = videoJob("C", videoID: "3",
                     .failed(StepFailure(kind: .noArtifact, summary: "no artifact")))
    let subject = InspectorSubject.resolve(
      destination: .queue, queueSelection: [a.id, b.id, c.id],
      watchingSelection: nil, sections: [], library: VideoLibrary(), jobs: [a, b, c])
    guard case .many(let many) = subject else {
      Issue.record("expected .many, got \(subject)")
      return
    }
    #expect(many.count == 3)
    #expect(many.queued == 2)
    #expect(many.failed == 1)
    #expect(many.running == 0)
    #expect(many.done == 0)
    #expect(many.cancelled == 0)
  }

  /// **The estimate is not attempted yet, and absent is the honest answer.**
  /// Slice D fills it; §5.3 forbids a partial sum, so nil here is the same
  /// value it will carry whenever a selection cannot be fully priced.
  @Test func theEstimateIsAbsentUntilItCanBeComputed() {
    let a = videoJob("A", videoID: "1")
    let b = videoJob("B", videoID: "2")
    guard case .many(let many) = InspectorSubject.resolve(
      destination: .queue, queueSelection: [a.id, b.id], watchingSelection: nil,
      sections: [], library: VideoLibrary(), jobs: [a, b])
    else {
      Issue.record("expected .many")
      return
    }
    #expect(many.estimatedBytes == nil)
  }

  // MARK: - The Watching side

  private func archive(_ id: String) -> ChannelArchive {
    ChannelArchive(id: id, title: "Stream \(id)", duration: .seconds(3600),
                   publishedAt: Date(timeIntervalSince1970: 0), status: .recorded,
                   thumbnailURL: nil)
  }

  private func section(
    _ login: String, rows: [String], allRows: [String]
  ) -> WatchingModel.Section {
    WatchingModel.Section(
      login: login, displayName: login.capitalized,
      rows: rows.map { WatchingModel.Row(archive: archive($0), state: .available) },
      allRows: allRows.map { WatchingModel.Row(archive: archive($0), state: .available) },
      failure: nil, settingsSummary: "", downloadsAutomatically: false)
  }

  /// An archive id *is* a video id — `video-record.md` §3.1's "join key to
  /// everything", and the reason this whole design is cheap.
  @Test func theInboxResolvesToItsSelectedArchive() {
    let s = section("leighxp", rows: ["abc"], allRows: ["abc", "old"])
    #expect(InspectorSubject.resolve(
      destination: .watching, queueSelection: [], watchingSelection: "abc",
      sections: [s], library: VideoLibrary(), jobs: []) == .one(.video("abc")))
  }

  /// A channel destination shows `allRows`, so a row the inbox holds back is
  /// still selectable there.
  @Test func aChannelResolvesAgainstItsWholeRecord() {
    let s = section("leighxp", rows: ["abc"], allRows: ["abc", "old"])
    #expect(InspectorSubject.resolve(
      destination: .channel("leighxp"), queueSelection: [], watchingSelection: "old",
      sections: [s], library: VideoLibrary(), jobs: []) == .one(.video("old")))
  }

  /// §3.2: one piece of state resolved against whatever is showing. Selecting
  /// in LeighXP and switching to AvaBamby is not an error and needs no reset
  /// step — the id simply matches nothing there.
  @Test func aSelectionFromAnotherChannelResolvesToNothing() {
    let leigh = section("leighxp", rows: ["abc"], allRows: ["abc"])
    let ava = section("avabamby", rows: ["zzz"], allRows: ["zzz"])
    #expect(InspectorSubject.resolve(
      destination: .channel("avabamby"), queueSelection: [], watchingSelection: "abc",
      sections: [leigh, ava], library: VideoLibrary(), jobs: []) == .nothing)
  }

  @Test func noWatchingSelectionIsNothing() {
    let s = section("leighxp", rows: ["abc"], allRows: ["abc"])
    #expect(InspectorSubject.resolve(
      destination: .watching, queueSelection: [], watchingSelection: nil,
      sections: [s], library: VideoLibrary(), jobs: []) == .nothing)
  }

  /// §3.3: `.many` can arise only from the queue. A future multi-select in
  /// Watching should have to come back to the design rather than inherit one.
  @Test func theWatchingSideNeverProducesMany() {
    let s = section("leighxp", rows: ["abc"], allRows: ["abc"])
    let j = videoJob("A", videoID: "1")
    let k = videoJob("B", videoID: "2")
    for destination: SidebarItem in [.watching, .channel("leighxp")] {
      let subject = InspectorSubject.resolve(
        destination: destination, queueSelection: [j.id, k.id],
        watchingSelection: "abc", sections: [s], library: VideoLibrary(), jobs: [j, k])
      if case .many = subject { Issue.record("\(destination) produced .many") }
    }
  }

  /// **A nil destination is the queue, because the window shows the queue.**
  ///
  /// `QueueView`'s detail switch renders `queue` for `case .none` — a `List`
  /// reports "nothing selected" as nil, most visibly when someone
  /// command-clicks the current sidebar row off. The inspector has to agree
  /// with the pane a person is actually looking at; resolving to `.nothing`
  /// there would blank the pane while a selected queue row sat beside it.
  ///
  /// This replaces a weaker assertion written before the Watching branches
  /// existed, when nil was simply lumped in with "not the queue".
  // MARK: - Pricing a multi-selection (§5.3)

  private let sd = StreamQuality(name: "360p30", resolution: "640x360",
                                 bitsPerSecond: 1_000_000)

  /// A record that can be priced: it has both a duration and the quality the
  /// job is downloading at.
  private func priceable(_ id: String) -> VideoRecord {
    VideoRecord(id: id, title: "Stream \(id)", durationSeconds: 3600,
                qualities: [sd])
  }

  private func library(_ records: [VideoRecord]) -> VideoLibrary {
    VideoLibrary(videos: Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) }))
  }

  private func many(
    _ jobs: [Job], _ library: VideoLibrary
  ) -> MultiSelection? {
    guard case .many(let m) = InspectorSubject.resolve(
      destination: .queue, queueSelection: Set(jobs.map(\.id)),
      watchingSelection: nil, sections: [], library: library, jobs: jobs)
    else { return nil }
    return m
  }

  @Test func everySelectedJobPriceableYieldsAnEstimate() throws {
    let a = videoJob("A", videoID: "1")
    let b = videoJob("B", videoID: "2")
    let m = try #require(many([a, b], library([priceable("1"), priceable("2")])))
    let bytes = try #require(m.estimatedBytes)
    // An hour at 1 Mbps is ~450 MB; two of them, and nothing is free.
    #expect(bytes > 0)
  }

  /// **§5.3, and the one that must not regress into a partial sum.**
  /// Mutation-check it: "incomplete" is not "smaller", and a test can appear
  /// to cover this while passing against a total that silently dropped a job.
  @Test func oneJobWithNoRecordOmitsTheEstimateEntirely() throws {
    let a = videoJob("A", videoID: "1")
    let b = videoJob("B", videoID: "2")
    // Only "1" is in the record, so "2" cannot be priced at all.
    let m = try #require(many([a, b], library([priceable("1")])))
    #expect(m.estimatedBytes == nil, "omitted, never partial")
    #expect(m.count == 2, "but the selection is still fully counted")
  }

  /// A row the record knows about but has no duration for — every field on
  /// `VideoRecord` is optional, and `durationSeconds` is the one pricing needs.
  @Test func aRecordWithNoDurationIsUnpriceable() throws {
    let a = videoJob("A", videoID: "1")
    let b = videoJob("B", videoID: "2")
    let m = try #require(many([a, b], library([
      priceable("1"),
      VideoRecord(id: "2", title: "no duration", qualities: [sd]),
    ])))
    #expect(m.estimatedBytes == nil)
  }

  /// The job names a rendition the record has never heard of, so there is no
  /// bitrate to price it at. Guessing a nominal one is exactly what §5.3
  /// forbids — the figure is one people act on.
  @Test func aQualityTheRecordDoesNotCarryIsUnpriceable() throws {
    let a = videoJob("A", videoID: "1")
    let b = videoJob("B", videoID: "2")
    let m = try #require(many([a, b], library([
      priceable("1"),
      VideoRecord(id: "2", title: "other quality", durationSeconds: 3600,
                  qualities: [StreamQuality(name: "1080p60", resolution: "1920x1080",
                                            bitsPerSecond: 6_000_000)]),
    ])))
    #expect(m.estimatedBytes == nil)
  }

  // MARK: - The stack (§5.1)

  private func withThumbnail(_ id: String, _ url: String) -> VideoRecord {
    VideoRecord(id: id, title: "Stream \(id)", durationSeconds: 3600,
                qualities: [sd], thumbnailURLs: [URL(string: url)!])
  }

  /// **Built deliberately out of queue order.** A `Set` will often *happen* to
  /// iterate plausibly, so a test that builds the selection in queue order
  /// proves nothing about the thing §5.1 is guarding against.
  @Test func theStackIsOrderedByQueuePositionNotBySelection() throws {
    let jobs = (1...5).map { videoJob("J\($0)", videoID: "\($0)") }
    let lib = library((1...5).map { withThumbnail("\($0)", "https://x/\($0).jpg") })
    // Selected last-to-first; the stack must still read 1, 2, 3, 4.
    let picked = Set([jobs[4], jobs[2], jobs[0], jobs[3], jobs[1]].map(\.id))
    guard case .many(let m) = InspectorSubject.resolve(
      destination: .queue, queueSelection: picked, watchingSelection: nil,
      sections: [], library: lib, jobs: jobs)
    else { Issue.record("expected .many"); return }

    #expect(m.count == 5, "the count keeps telling the truth")
    #expect(m.thumbnails.count == 4, "capped at four")
    #expect(m.thumbnails.map { $0?.absoluteString } == [
      "https://x/1.jpg", "https://x/2.jpg", "https://x/3.jpg", "https://x/4.jpg",
    ])
  }

  /// A job whose video has no thumbnail keeps its place as nil, so the stack
  /// draws a placeholder tile rather than collapsing to a shorter fan.
  @Test func aJobWithNoThumbnailKeepsItsPlaceAsNil() throws {
    let a = videoJob("A", videoID: "1")
    let b = videoJob("B", videoID: "2")
    let c = videoJob("C", videoID: "3")
    let lib = library([
      withThumbnail("1", "https://x/1.jpg"),
      priceable("2"),                                   // no thumbnailURLs
      withThumbnail("3", "https://x/3.jpg"),
    ])
    guard case .many(let m) = InspectorSubject.resolve(
      destination: .queue, queueSelection: Set([a, b, c].map(\.id)),
      watchingSelection: nil, sections: [], library: lib, jobs: [a, b, c])
    else { Issue.record("expected .many"); return }
    #expect(m.thumbnails.map { $0?.absoluteString }
      == ["https://x/1.jpg", nil, "https://x/3.jpg"])
  }

  /// The line under the count, and the reason `VideoRecord.displayName`
  /// exists: before it this would have read "leighxp, wheelyf".
  @Test func theChannelsAreDisplayNamesInQueueOrderWithoutRepeats() throws {
    let jobs = (1...4).map { videoJob("J\($0)", videoID: "\($0)") }
    let lib = library([
      VideoRecord(id: "1", displayName: "LeighXP", durationSeconds: 60, qualities: [sd]),
      VideoRecord(id: "2", displayName: "WheelyF", durationSeconds: 60, qualities: [sd]),
      VideoRecord(id: "3", displayName: "LeighXP", durationSeconds: 60, qualities: [sd]),
      VideoRecord(id: "4", displayName: "AvaBamby", durationSeconds: 60, qualities: [sd]),
    ])
    guard case .many(let m) = InspectorSubject.resolve(
      destination: .queue, queueSelection: Set(jobs.map(\.id)),
      watchingSelection: nil, sections: [], library: lib, jobs: jobs)
    else { Issue.record("expected .many"); return }
    #expect(m.channels == ["LeighXP", "WheelyF", "AvaBamby"])
  }

  /// **A record with no display name falls back to its login, never to
  /// nothing.** Observed naming two of three channels because the third was
  /// never watched and so never backfilled — a line listing the channels that
  /// silently drops one is the same partial-answer mistake `estimatedBytes`
  /// refuses.
  @Test func aChannelWithNoRememberedNameFallsBackToItsLogin() throws {
    let a = videoJob("A", videoID: "1")
    let b = videoJob("B", videoID: "2")
    let lib = library([
      VideoRecord(id: "1", displayName: "LeighXP", durationSeconds: 60, qualities: [sd]),
      VideoRecord(id: "2", login: "lilbadsnacks", durationSeconds: 60, qualities: [sd]),
    ])
    guard case .many(let m) = InspectorSubject.resolve(
      destination: .queue, queueSelection: Set([a, b].map(\.id)),
      watchingSelection: nil, sections: [], library: lib, jobs: [a, b])
    else { Issue.record("expected .many"); return }
    #expect(m.channels == ["LeighXP", "lilbadsnacks"])
  }

  /// Only a record with neither is skipped — there is nothing to print.
  @Test func aChannelWithNeitherNameNorLoginIsSkipped() throws {
    let a = videoJob("A", videoID: "1")
    let b = videoJob("B", videoID: "2")
    let lib = library([
      VideoRecord(id: "1", displayName: "LeighXP", durationSeconds: 60, qualities: [sd]),
      VideoRecord(id: "2", durationSeconds: 60, qualities: [sd]),
    ])
    guard case .many(let m) = InspectorSubject.resolve(
      destination: .queue, queueSelection: Set([a, b].map(\.id)),
      watchingSelection: nil, sections: [], library: lib, jobs: [a, b])
    else { Issue.record("expected .many"); return }
    #expect(m.channels == ["LeighXP"])
  }

  @Test func noDestinationFollowsTheQueueTheWindowIsShowing() {
    let j = videoJob("A", videoID: "1")
    #expect(InspectorSubject.resolve(
      destination: nil, queueSelection: [j.id], watchingSelection: nil,
      sections: [], library: VideoLibrary(), jobs: [j]) == .one(.video("1")))
    #expect(InspectorSubject.resolve(
      destination: nil, queueSelection: [], watchingSelection: nil,
      sections: [], library: VideoLibrary(), jobs: [j]) == .nothing)
  }
}
