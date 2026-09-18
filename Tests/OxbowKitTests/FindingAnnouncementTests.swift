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

  /// Empty handled set except in tests exercising that filter.
  private func watch(_ login: String, seen: Set<String> = []) -> Watch {
    Watch(login: login, displayName: login.capitalized,
          settings: Watch.Settings(
            destinationPath: "/tmp", qualityCap: .best,
            output: .videoWithChat, chatSize: .medium),
          downloadsAutomatically: false, seen: seen)
  }

  // MARK: - Saying nothing

  @Test("A sweep that found nothing says nothing")
  func quietSweep() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", [])], watches: [watch("ninja")], submitted: [],
      alreadyAnnounced: [])

    #expect(decision.message == nil)
    #expect(decision.announced.isEmpty)
  }

  @Test("A failed fetch is not a finding to announce")
  func failedFetchAnnouncesNothing() {
    let decision = FindingAnnouncement.decide(
      results: [WatchPollResult(login: "ninja", displayName: "Ninja",
                                outcome: .failed(.noSuchChannel))],
      watches: [watch("ninja")], submitted: [], alreadyAnnounced: [])

    #expect(decision.message == nil)
  }

  /// Unacted-on findings recur every sweep; announce each only once.
  @Test("A finding already announced is not announced again")
  func alreadyAnnouncedStaysQuiet() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1"])], watches: [watch("ninja")], submitted: [],
      alreadyAnnounced: ["1"])

    #expect(decision.message == nil)
    #expect(decision.announced == ["1"])
  }

  /// §6.2's automatic path already queued it, and `JobNotifier` will report
  /// that job on its own. Calling it "waiting" would be false twice over.
  @Test("An archive this sweep auto-submitted is never announced as waiting")
  func submittedIsNotWaiting() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1", "2"])], watches: [watch("ninja")],
      submitted: ["1", "2"], alreadyAnnounced: [])

    #expect(decision.message == nil)
    #expect(decision.announced.isEmpty)
  }

  // MARK: - Saying something

  @Test("One new archive from one channel names the channel")
  func singleFinding() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1"])], watches: [watch("ninja")], submitted: [],
      alreadyAnnounced: [])

    #expect(decision.message?.title == "New archive from Ninja")
    #expect(decision.message?.body == "1 archive is waiting in Watching.")
    #expect(decision.announced == ["1"])
  }

  @Test("Several from one channel still names the channel")
  func severalFromOneChannel() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1", "2", "3"])], watches: [watch("ninja")],
      submitted: [], alreadyAnnounced: [])

    #expect(decision.message?.title == "3 new archives from Ninja")
    #expect(decision.message?.body == "3 archives are waiting in Watching.")
  }

  @Test("Across channels, the count of channels replaces the name")
  func acrossChannels() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1"]), found("leighxp", "LeighXP", ["2"])],
      watches: [watch("ninja"), watch("leighxp")], submitted: [], alreadyAnnounced: [])

    #expect(decision.message?.title == "2 new archives from 2 channels")
    #expect(decision.announced == ["1", "2"])
  }

  /// A channel that turned up nothing is not one of the channels the title
  /// counts — otherwise every quiet watch would inflate the number.
  @Test("Only channels with something new are counted")
  func quietChannelsDoNotCount() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1"]), found("leighxp", "LeighXP", [])],
      watches: [watch("ninja"), watch("leighxp")], submitted: [], alreadyAnnounced: [])

    #expect(decision.message?.title == "New archive from Ninja")
  }

  /// Notification count includes all waiting rows, not only newly announced ones.
  @Test("The body counts everything waiting, the title only what is new")
  func bodyCountsAllWaiting() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1", "2", "3"])], watches: [watch("ninja")],
      submitted: [], alreadyAnnounced: ["1", "2"])

    #expect(decision.message?.title == "New archive from Ninja")
    #expect(decision.message?.body == "3 archives are waiting in Watching.")
  }

  @Test("What was submitted is excluded from the waiting count too")
  func submittedIsNotCountedAsWaiting() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1", "2"])], watches: [watch("ninja")],
      submitted: ["2"], alreadyAnnounced: [])

    #expect(decision.message?.title == "New archive from Ninja")
    #expect(decision.message?.body == "1 archive is waiting in Watching.")
  }

  // MARK: - What is carried forward

  /// Drop IDs absent from later sweeps to bound remembered announcements.
  @Test("An id that stopped appearing is dropped from what is remembered")
  func vanishedIdsArePruned() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["2"])], watches: [watch("ninja")], submitted: [],
      alreadyAnnounced: ["1", "2"])

    #expect(decision.announced == ["2"])
  }

  /// A failed automatic download needs its first announcement when it returns for manual
  /// attention.
  @Test("An archive that returns to the inbox after a failure is announced then")
  func returnsAfterFailure() {
    let queued = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1"])], watches: [watch("ninja")],
      submitted: ["1"], alreadyAnnounced: [])
    #expect(queued.message == nil)

    let returned = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1"])], watches: [watch("ninja")], submitted: [],
      alreadyAnnounced: queued.announced)

    #expect(returned.message?.title == "New archive from Ninja")
  }

  // MARK: - Filtering by seen

  /// Filter handled IDs at the consumer; raw sweeps include them.
  @Test("an archive already in seen is never announced, whatever the sweep hands over")
  func seenArchivesAreNeverAnnounced() {
    let watch = Watch(
      login: "ninja", displayName: "Ninja",
      settings: Watch.Settings(
        destinationPath: "/tmp", qualityCap: .best,
        output: .videoWithChat, chatSize: .medium),
      downloadsAutomatically: false, seen: ["1"])

    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1", "2"])], watches: [watch],
      submitted: [], alreadyAnnounced: [])

    #expect(decision.message?.title == "New archive from Ninja")
    #expect(decision.message?.body == "1 archive is waiting in Watching.")
    #expect(decision.announced == ["2"], "the seen archive must not be remembered either")
  }

  /// Ignore results for a channel stopped mid-sweep.
  @Test("a result with no matching watch is skipped, not passed through")
  func resultWithoutAWatchIsSkipped() {
    let decision = FindingAnnouncement.decide(
      results: [found("ninja", "Ninja", ["1"])], watches: [],
      submitted: [], alreadyAnnounced: [])

    #expect(decision.message == nil)
    #expect(decision.announced.isEmpty)
  }
}
