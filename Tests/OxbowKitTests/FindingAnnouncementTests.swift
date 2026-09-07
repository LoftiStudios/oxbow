import Foundation
import Testing
@testable import OxbowKit

@Suite("FindingAnnouncement")
struct FindingAnnouncementTests {

  private func archive(_ id: String) -> ChannelArchive {
    ChannelArchive(id: id, title: "t", duration: .seconds(60),
                   publishedAt: Date(timeIntervalSince1970: 0), status: .recorded,
                   thumbnailURL: nil)
  }

  private func found(_ login: String, _ name: String, _ ids: [String]) -> WatchPollResult {
    WatchPollResult(login: login, displayName: name, outcome: .found(ids.map(archive)))
  }

  // MARK: - Saying nothing

  @Test("A sweep that found nothing says nothing")
  func quietSweep() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", [])], submitted: [], alreadyAnnounced: [])

    #expect(decision.message == nil)
    #expect(decision.announced.isEmpty)
  }

  @Test("A failed fetch is not a finding to announce")
  func failedFetchAnnouncesNothing() {
    let decision = FindingAnnouncement.decide(
      results: [WatchPollResult(login: "ninja", displayName: "Ninja",
                                outcome: .failed(.noSuchChannel))],
      submitted: [], alreadyAnnounced: [])

    #expect(decision.message == nil)
  }

  /// The nag this rule exists to prevent. A finding sits in the inbox until
  /// it is added or ignored, and every sweep re-reports it — so "there are
  /// findings" as the trigger would announce the same rows hourly, forever.
  @Test("A finding already announced is not announced again")
  func alreadyAnnouncedStaysQuiet() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1"])], submitted: [], alreadyAnnounced: ["1"])

    #expect(decision.message == nil)
    #expect(decision.announced == ["1"])
  }

  /// §6.2's automatic path already queued it, and `JobNotifier` will report
  /// that job on its own. Calling it "waiting" would be false twice over.
  @Test("An archive this sweep auto-submitted is never announced as waiting")
  func submittedIsNotWaiting() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1", "2"])], submitted: ["1", "2"],
      alreadyAnnounced: [])

    #expect(decision.message == nil)
    #expect(decision.announced.isEmpty)
  }

  // MARK: - Saying something

  @Test("One new archive from one channel names the channel")
  func singleFinding() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1"])], submitted: [], alreadyAnnounced: [])

    #expect(decision.message?.title == "New archive from Ninja")
    #expect(decision.message?.body == "1 archive is waiting in Watching.")
    #expect(decision.announced == ["1"])
  }

  @Test("Several from one channel still names the channel")
  func severalFromOneChannel() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1", "2", "3"])], submitted: [],
      alreadyAnnounced: [])

    #expect(decision.message?.title == "3 new archives from Ninja")
    #expect(decision.message?.body == "3 archives are waiting in Watching.")
  }

  @Test("Across channels, the count of channels replaces the name")
  func acrossChannels() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1"]), found("leighxp", "LeighXP", ["2"])],
      submitted: [], alreadyAnnounced: [])

    #expect(decision.message?.title == "2 new archives from 2 channels")
    #expect(decision.announced == ["1", "2"])
  }

  /// A channel that turned up nothing is not one of the channels the title
  /// counts — otherwise every quiet watch would inflate the number.
  @Test("Only channels with something new are counted")
  func quietChannelsDoNotCount() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1"]), found("leighxp", "LeighXP", [])],
      submitted: [], alreadyAnnounced: [])

    #expect(decision.message?.title == "New archive from Ninja")
  }

  /// §2.2 requires the notification to say how many are waiting, which is not
  /// the same number as how many are new: two rows a person has already been
  /// told about are still sitting there unacted on.
  @Test("The body counts everything waiting, the title only what is new")
  func bodyCountsAllWaiting() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1", "2", "3"])], submitted: [],
      alreadyAnnounced: ["1", "2"])

    #expect(decision.message?.title == "New archive from Ninja")
    #expect(decision.message?.body == "3 archives are waiting in Watching.")
  }

  @Test("What was submitted is excluded from the waiting count too")
  func submittedIsNotCountedAsWaiting() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1", "2"])], submitted: ["2"],
      alreadyAnnounced: [])

    #expect(decision.message?.title == "New archive from Ninja")
    #expect(decision.message?.body == "1 archive is waiting in Watching.")
  }

  // MARK: - What is carried forward

  /// An archive that has expired off Twitch stops appearing in a sweep, so
  /// holding its id forever would grow this set for the life of the process
  /// with entries nothing can ever match again.
  @Test("An id that stopped appearing is dropped from what is remembered")
  func vanishedIdsArePruned() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["2"])], submitted: [],
      alreadyAnnounced: ["1", "2"])

    #expect(decision.announced == ["2"])
  }

  /// The concrete case: an automatic download fails, §6.3 un-marks it, and it
  /// returns as an ordinary finding. It was never announced when it queued,
  /// so this is the first time a person is told it needs them — and the set
  /// must not have been holding it from the sweep that submitted it.
  @Test("An archive that returns to the inbox after a failure is announced then")
  func returnsAfterFailure() {
    let queued = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1"])], submitted: ["1"], alreadyAnnounced: [])
    #expect(queued.message == nil)

    let returned = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1"])], submitted: [],
      alreadyAnnounced: queued.announced)

    #expect(returned.message?.title == "New archive from Ninja")
  }
}
