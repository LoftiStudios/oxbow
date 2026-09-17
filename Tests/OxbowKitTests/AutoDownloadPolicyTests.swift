import Foundation
import Testing
@testable import OxbowKit

@Suite("AutoDownloadPolicy")
struct AutoDownloadPolicyTests {

  private let settings = Watch.Settings(
    destinationPath: "/Users/x/Downloads", qualityCap: .p1080,
    output: .videoWithChat, chatSize: .medium)

  private func watch(automatic: Bool = true, seen: Set<String> = []) -> Watch {
    Watch(login: "ninja", displayName: "Ninja", settings: settings,
          downloadsAutomatically: automatic, seen: seen)
  }

  private func archive(_ id: String, status: ChannelArchive.Status = .recorded) -> ChannelArchive {
    ChannelArchive(id: id, title: "t", duration: .seconds(60),
                   publishedAt: Date(timeIntervalSince1970: 0), status: status, thumbnailURL: nil)
  }

  private let floor: Int64 = Preferences.factoryFreeSpaceFloor

  /// Compute batch cost with the policy's estimator so tests can set exact capacity boundaries.
  private func cost(_ archives: [ChannelArchive]) -> Int64 {
    BackfillEstimate(archives: archives, cap: settings.qualityCap, output: settings.output).bytes
  }

  // 1. downloadsAutomatically == false returns .notAutomatic, not .submit([])
  @Test("a watch with automatic downloading off returns notAutomatic, not an empty submit")
  func offReturnsNotAutomatic() {
    let decision = AutoDownloadPolicy.decide(
      watch: watch(automatic: false), findings: [archive("1")],
      availableBytes: floor + 1, destinationExists: true, floor: floor)
    #expect(decision == .notAutomatic)
  }

  // 2. Only isDownloadable archives are submitted.
  @Test("a recording live broadcast is skipped, even though it is a finding")
  func recordingIsSkipped() {
    // Supply enough space for the only downloadable finding.
    let decision = AutoDownloadPolicy.decide(
      watch: watch(), findings: [archive("1", status: .recording), archive("2")],
      availableBytes: floor + cost([archive("2")]), destinationExists: true, floor: floor)
    #expect(decision == .submit([archive("2")]))
  }

  // 3. Below the floor demotes, carrying all three numbers.
  @Test("available space under the floor demotes with what it wanted and what there is")
  func belowFloorDemotes() {
    let decision = AutoDownloadPolicy.decide(
      watch: watch(), findings: [archive("1")],
      availableBytes: floor - 1, destinationExists: true, floor: floor)
    #expect(decision == .demoted(.belowFloor(
      needed: cost([archive("1")]), available: floor - 1, floor: floor)))
  }

  /// The reserve applies after subtracting download cost.
  @Test("a download that fits above the floor is submitted even on a nearly full volume")
  func aSmallDownloadFitsOnATightVolume() {
    let one = archive("1")
    let decision = AutoDownloadPolicy.decide(
      watch: watch(), findings: [one],
      availableBytes: floor + cost([one]), destinationExists: true, floor: floor)
    #expect(decision == .submit([one]))
  }

  /// Insufficient space must demote, not report an empty successful batch.
  @Test("one byte short of fitting demotes rather than submitting an empty batch")
  func oneByteShortDemotes() {
    let one = archive("1")
    let decision = AutoDownloadPolicy.decide(
      watch: watch(), findings: [one],
      availableBytes: floor + cost([one]) - 1, destinationExists: true, floor: floor)
    #expect(decision == .demoted(.belowFloor(
      needed: cost([one]), available: floor + cost([one]) - 1, floor: floor)))
  }

  // 4. An unreachable destination demotes, carrying the path.
  @Test("an unreachable destination demotes with the path")
  func unreachableDestinationDemotes() {
    let decision = AutoDownloadPolicy.decide(
      watch: watch(), findings: [archive("1")],
      availableBytes: floor + 1, destinationExists: false, floor: floor)
    #expect(decision == .demoted(.destinationUnreachable(settings.destinationPath)))
  }

  // Caller supplies capacity for the destination volume.
  @Test("availableBytes, whatever volume it was resolved for, is what is compared to the floor")
  func availableBytesIsComparedDirectly() {
    // Exactly meeting the reserve is allowed.
    let atFloor = AutoDownloadPolicy.decide(
      watch: watch(), findings: [archive("1")],
      availableBytes: floor + cost([archive("1")]), destinationExists: true, floor: floor)
    #expect(atFloor == .submit([archive("1")]))
  }

  // Recovered conditions allow a later sweep; demotion is not persisted policy state.
  @Test("a watch demoted on one call submits normally on the next once conditions recover")
  func demotionDoesNotPersistAcrossCalls() {
    let firstSweep = AutoDownloadPolicy.decide(
      watch: watch(), findings: [archive("1")],
      availableBytes: floor - 1, destinationExists: true, floor: floor)
    #expect(firstSweep == .demoted(.belowFloor(
      needed: cost([archive("1")]), available: floor - 1, floor: floor)))

    let secondSweep = AutoDownloadPolicy.decide(
      watch: watch(), findings: [archive("1")],
      availableBytes: floor + cost([archive("1")]), destinationExists: true, floor: floor)
    #expect(secondSweep == .submit([archive("1")]))
  }

  // Take the fitting prefix in order and leave remaining findings for later.
  @Test("a sweep submits only as many findings as keep free space at or above the floor")
  func stopsSubmittingOnceTheRunningCostWouldBreachTheFloor() {
    let archives = [archive("1"), archive("2"), archive("3")]
    let twoFit = cost([archive("1"), archive("2")])

    let decision = AutoDownloadPolicy.decide(
      watch: watch(), findings: archives,
      // Enough for the first two and nothing more: adding the third would
      // take the volume below the floor by construction.
      availableBytes: floor + twoFit, destinationExists: true, floor: floor)

    #expect(decision == .submit([archive("1"), archive("2")]))
  }

  // The first nonfitting finding remains eligible for a later sweep.
  @Test("a finding the batch bound stops at is excluded from submit, not queued anyway")
  func excludedFindingIsNotInTheSubmitSet() {
    let onlyOneFits = cost([archive("1")])
    let decision = AutoDownloadPolicy.decide(
      watch: watch(), findings: [archive("1"), archive("2")],
      availableBytes: floor + onlyOneFits, destinationExists: true, floor: floor)
    #expect(decision == .submit([archive("1")]))
  }

  // 7. An empty finding list with automatic on returns .submit([]).
  @Test("no findings with automatic on returns an empty submit, not notAutomatic")
  func emptyFindingsSubmitsEmpty() {
    let decision = AutoDownloadPolicy.decide(
      watch: watch(), findings: [],
      availableBytes: floor + 1, destinationExists: true, floor: floor)
    #expect(decision == .submit([]))
  }

  // 8. Precedence: an unreachable destination beats a low floor.
  @Test("an unreachable destination wins over a low floor when both apply")
  func unreachableDestinationWinsOverLowFloor() {
    let decision = AutoDownloadPolicy.decide(
      watch: watch(), findings: [archive("1")],
      availableBytes: floor - 1, destinationExists: false, floor: floor)
    #expect(decision == .demoted(.destinationUnreachable(settings.destinationPath)))
  }

  // Include download cost in the reason so reserve size cannot be mistaken for output size.
  @Test("belowFloor states the cost, the free space and the reserve")
  func belowFloorSentence() {
    let reason = AutoDownloadPolicy.Reason.belowFloor(
      needed: 2_600_000_000, available: 124_000_000_000, floor: 250_000_000_000)
    #expect(reason.sentence.contains("2.6 GB"))
    #expect(reason.sentence.contains("124 GB"))
    #expect(reason.sentence.contains("250 GB"))
  }

  @Test("destinationUnreachable states the path in its sentence")
  func destinationUnreachableSentence() {
    let reason = AutoDownloadPolicy.Reason.destinationUnreachable("/Volumes/Archive")
    #expect(reason.sentence.contains("/Volumes/Archive"))
  }

  // MARK: - A channel whose archives are subscriber-only

  private func restrictedJob(_ id: String) -> Job {
    Job(
      id: JobID(rawValue: UUID()), created: Date(timeIntervalSince1970: 0),
      title: "t",
      steps: [Step(
        id: StepID(rawValue: UUID()),
        kind: .downloadVideo(VideoRequest(
          videoID: id, quality: "", destination: URL(filePath: "/out/\(id).mp4"))),
        status: .failed(StepFailure(
          kind: .exited(code: 134),
          summary: FailureInterpreter.subscriberOnlySummary)))])
  }

  private func otherFailedJob(_ id: String) -> Job {
    Job(
      id: JobID(rawValue: UUID()), created: Date(timeIntervalSince1970: 0),
      title: "t",
      steps: [Step(
        id: StepID(rawValue: UUID()),
        kind: .downloadVideo(VideoRequest(
          videoID: id, quality: "", destination: URL(filePath: "/out/\(id).mp4"))),
        status: .failed(StepFailure(kind: .noArtifact, summary: "Something else went wrong.")))])
  }

  /// Two restricted videos may be isolated exceptions; do not demote the whole channel yet.
  @Test("two subscriber-only failures are not enough to call the channel restricted")
  func twoIsNotEnough() {
    #expect(!AutoDownloadPolicy.isContentRestricted(
      jobs: [restrictedJob("1"), restrictedJob("2")]))
  }

  @Test("three subscriber-only failures make it a channel-level fact")
  func threeIsEnough() {
    #expect(AutoDownloadPolicy.isContentRestricted(
      jobs: [restrictedJob("1"), restrictedJob("2"), restrictedJob("3")]))
  }

  /// Failures that are not this one must not count toward the threshold, or
  /// three unrelated network hiccups would silently stop a channel.
  @Test("other failures do not count toward the threshold")
  func otherFailuresDoNotCount() {
    #expect(!AutoDownloadPolicy.isContentRestricted(
      jobs: [restrictedJob("1"), otherFailedJob("2"), otherFailedJob("3")]))
  }

  /// Demotion stops automatic downloading while findings remain visible.
  @Test("a restricted channel demotes rather than submitting")
  func restrictedChannelDemotes() {
    let decision = AutoDownloadPolicy.decide(
      watch: watch(), findings: [archive("1")],
      availableBytes: floor + cost([archive("1")]),
      destinationExists: true, contentRestricted: true, floor: floor)
    #expect(decision == .demoted(.contentRestricted))
  }

  /// Content restriction takes precedence over transient disk or volume problems.
  @Test("restriction is reported ahead of a missing destination or a low disk")
  func restrictionOutranksTheOthers() {
    let bothWrong = AutoDownloadPolicy.decide(
      watch: watch(), findings: [archive("1")], availableBytes: 0,
      destinationExists: false, contentRestricted: true, floor: floor)
    #expect(bothWrong == .demoted(.contentRestricted))
  }

  @Test("contentRestricted names the cause and does not promise a remedy")
  func restrictedSentence() {
    let sentence = AutoDownloadPolicy.Reason.contentRestricted.sentence
    #expect(sentence.contains("subscriber"))
  }

  /// Suppress only the separately announced unmounted-volume case; other demotions need their
  /// own explanation.
  @Test("only a missing destination counts as unreachable")
  func onlyTheDestinationCaseIsUnreachable() {
    #expect(AutoDownloadPolicy.Reason.destinationUnreachable("/Volumes/Storage")
      .isDestinationUnreachable)
    #expect(!AutoDownloadPolicy.Reason.contentRestricted.isDestinationUnreachable)
    #expect(!AutoDownloadPolicy.Reason
      .belowFloor(needed: 1, available: 2, floor: 3).isDestinationUnreachable)
  }

}
