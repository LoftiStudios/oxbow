import Foundation
import Testing
import OxbowKit
@testable import Oxbow

/// Tests inspector selection resolution over plain values without constructing a view.
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

  /// An unpriceable selection must report no estimate, never a partial sum.
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

  /// Archive IDs directly identify video records.
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

  /// Switching channels resolves selection against the new rows; stale IDs need no explicit
  /// reset.
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

  /// Nil sidebar destination renders the queue, so the inspector must resolve against it too.

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
    // Each one-hour, 1 Mbps job costs approximately 450 MB.
    #expect(bytes > 0)
  }

  /// An incomplete estimate must be nil, not a smaller partial total.
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

  /// Unknown rendition means no bitrate estimate; do not invent one.
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

  /// Upward selection must put newly selected cards on top and retain earlier hidden cards.
  @Test func allArrivalsAreRetainedWithTheNewestOnTop() throws {
    let jobs = (1...5).map { videoJob("J\($0)", videoID: "\($0)") }
    let lib = library((1...5).map { withThumbnail("\($0)", "https://x/\($0).jpg") })
    // Picked 5 first, then 4, 3, 2, 1 — the order ⇧↑ produces from the bottom.
    let arrivals = [jobs[4], jobs[3], jobs[2], jobs[1], jobs[0]].map(\.id)

    guard case .many(let m) = InspectorSubject.resolve(
      destination: .queue, queueSelection: Set(arrivals), watchingSelection: nil,
      sections: [], library: lib, arrivals: arrivals, jobs: jobs)
    else { Issue.record("expected .many"); return }

    #expect(m.count == 5, "the count keeps telling the truth")
    #expect(m.cards.count == 5, "hidden cards remain available for removal animation")
    // Oldest first, including the hidden job 5; job 1 faces you.
    #expect(m.cards.map(\.id) == arrivals)
    #expect(m.cards.last?.url?.absoluteString == "https://x/1.jpg")
  }

  /// Fewer than the cap keeps every card, still oldest-first.
  @Test func aSmallSelectionKeepsEveryCard() throws {
    let jobs = (1...3).map { videoJob("J\($0)", videoID: "\($0)") }
    let lib = library((1...3).map { withThumbnail("\($0)", "https://x/\($0).jpg") })
    let arrivals = [jobs[2], jobs[0], jobs[1]].map(\.id)
    guard case .many(let m) = InspectorSubject.resolve(
      destination: .queue, queueSelection: Set(arrivals), watchingSelection: nil,
      sections: [], library: lib, arrivals: arrivals, jobs: jobs)
    else { Issue.record("expected .many"); return }
    #expect(m.cards.map(\.id) == arrivals)
  }

  /// A job whose video has no thumbnail keeps its place with a nil url, so the
  /// fan draws a placeholder tile rather than collapsing to a shorter pile.
  @Test func aJobWithNoThumbnailKeepsItsPlaceAsANilURL() throws {
    let a = videoJob("A", videoID: "1")
    let b = videoJob("B", videoID: "2")
    let c = videoJob("C", videoID: "3")
    let lib = library([
      withThumbnail("1", "https://x/1.jpg"),
      priceable("2"),                                   // no thumbnailURLs
      withThumbnail("3", "https://x/3.jpg"),
    ])
    let arrivals = [a, b, c].map(\.id)
    guard case .many(let m) = InspectorSubject.resolve(
      destination: .queue, queueSelection: Set(arrivals), watchingSelection: nil,
      sections: [], library: lib, arrivals: arrivals, jobs: [a, b, c])
    else { Issue.record("expected .many"); return }
    #expect(m.cards.map { $0.url?.absoluteString }
      == ["https://x/1.jpg", nil, "https://x/3.jpg"])
  }


  /// Channel labels prefer stored display names over logins.
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

  /// Missing display names fall back to login without dropping a selected channel.
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
