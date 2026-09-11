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
      sections: [], jobs: []) == .nothing)
  }

  @Test func oneQueueJobWithAVideoResolvesToThatVideo() {
    let j = videoJob("A", videoID: "123")
    #expect(InspectorSubject.resolve(
      destination: .queue, queueSelection: [j.id], watchingSelection: nil,
      sections: [], jobs: [j])
      == .one(.video("123")))
  }

  /// `video-record.md` §4.2: a job with no resolvable video id stays
  /// addressable, keyed by its `JobID` instead of becoming un-openable.
  @Test func oneQueueJobWithoutAVideoResolvesToTheJob() {
    let j = chatOnlyJob("A")
    #expect(InspectorSubject.resolve(
      destination: .queue, queueSelection: [j.id], watchingSelection: nil,
      sections: [], jobs: [j])
      == .one(.job(j.id)))
  }

  @Test func aSelectedIdThatMatchesNoJobIsNothing() {
    let j = videoJob("A", videoID: "123")
    #expect(InspectorSubject.resolve(
      destination: .queue, queueSelection: [JobID(rawValue: UUID())],
      watchingSelection: nil, sections: [], jobs: [j])
      == .nothing)
  }

  @Test func severalSelectedCountsThemByStatus() {
    let a = videoJob("A", videoID: "1", .queued)
    let b = videoJob("B", videoID: "2", .queued)
    let c = videoJob("C", videoID: "3",
                     .failed(StepFailure(kind: .noArtifact, summary: "no artifact")))
    let subject = InspectorSubject.resolve(
      destination: .queue, queueSelection: [a.id, b.id, c.id],
      watchingSelection: nil, sections: [], jobs: [a, b, c])
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
      sections: [], jobs: [a, b])
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
      sections: [s], jobs: []) == .one(.video("abc")))
  }

  /// A channel destination shows `allRows`, so a row the inbox holds back is
  /// still selectable there.
  @Test func aChannelResolvesAgainstItsWholeRecord() {
    let s = section("leighxp", rows: ["abc"], allRows: ["abc", "old"])
    #expect(InspectorSubject.resolve(
      destination: .channel("leighxp"), queueSelection: [], watchingSelection: "old",
      sections: [s], jobs: []) == .one(.video("old")))
  }

  /// §3.2: one piece of state resolved against whatever is showing. Selecting
  /// in LeighXP and switching to AvaBamby is not an error and needs no reset
  /// step — the id simply matches nothing there.
  @Test func aSelectionFromAnotherChannelResolvesToNothing() {
    let leigh = section("leighxp", rows: ["abc"], allRows: ["abc"])
    let ava = section("avabamby", rows: ["zzz"], allRows: ["zzz"])
    #expect(InspectorSubject.resolve(
      destination: .channel("avabamby"), queueSelection: [], watchingSelection: "abc",
      sections: [leigh, ava], jobs: []) == .nothing)
  }

  @Test func noWatchingSelectionIsNothing() {
    let s = section("leighxp", rows: ["abc"], allRows: ["abc"])
    #expect(InspectorSubject.resolve(
      destination: .watching, queueSelection: [], watchingSelection: nil,
      sections: [s], jobs: []) == .nothing)
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
        watchingSelection: "abc", sections: [s], jobs: [j, k])
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
  @Test func noDestinationFollowsTheQueueTheWindowIsShowing() {
    let j = videoJob("A", videoID: "1")
    #expect(InspectorSubject.resolve(
      destination: nil, queueSelection: [j.id], watchingSelection: nil,
      sections: [], jobs: [j]) == .one(.video("1")))
    #expect(InspectorSubject.resolve(
      destination: nil, queueSelection: [], watchingSelection: nil,
      sections: [], jobs: [j]) == .nothing)
  }
}
