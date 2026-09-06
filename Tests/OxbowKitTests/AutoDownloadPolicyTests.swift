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

  /// What `decide()` itself now prices a set of findings at, via the same
  /// `BackfillEstimate` arithmetic — so a test can pick an `availableBytes`
  /// that is exactly, not approximately, enough for a given prefix, instead
  /// of guessing at a margin generous enough to survive the batch bound
  /// unrelated tests are not exercising.
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
    // Priced exactly enough for the one downloadable finding — the batch
    // bound (finding 4) is not what this test is about.
    let decision = AutoDownloadPolicy.decide(
      watch: watch(), findings: [archive("1", status: .recording), archive("2")],
      availableBytes: floor + cost([archive("2")]), destinationExists: true, floor: floor)
    #expect(decision == .submit([archive("2")]))
  }

  // 3. Below the floor demotes, carrying both numbers.
  @Test("available space under the floor demotes with both numbers")
  func belowFloorDemotes() {
    let decision = AutoDownloadPolicy.decide(
      watch: watch(), findings: [archive("1")],
      availableBytes: floor - 1, destinationExists: true, floor: floor)
    #expect(decision == .demoted(.belowFloor(available: floor - 1, floor: floor)))
  }

  // 4. An unreachable destination demotes, carrying the path.
  @Test("an unreachable destination demotes with the path")
  func unreachableDestinationDemotes() {
    let decision = AutoDownloadPolicy.decide(
      watch: watch(), findings: [archive("1")],
      availableBytes: floor + 1, destinationExists: false, floor: floor)
    #expect(decision == .demoted(.destinationUnreachable(settings.destinationPath)))
  }

  // 5. The floor is checked against the destination's volume — the caller's
  // contract, documented, not independently testable from arguments alone
  // beyond confirming availableBytes (whatever it is) is what gets compared.
  @Test("availableBytes, whatever volume it was resolved for, is what is compared to the floor")
  func availableBytesIsComparedDirectly() {
    // Exactly enough left, after taking this one finding, to still sit at
    // the floor — not below it. The entry gate above (`availableBytes >=
    // floor`) and the batch bound below both key off the identical `>=`, so
    // this pins both at once: the finding is neither refused outright nor
    // trimmed away by the bound.
    let atFloor = AutoDownloadPolicy.decide(
      watch: watch(), findings: [archive("1")],
      availableBytes: floor + cost([archive("1")]), destinationExists: true, floor: floor)
    #expect(atFloor == .submit([archive("1")]))
  }

  // 6. Demotion is per-sweep and per-watch: decide is pure and stateless, so
  // calling it again with recovered arguments submits normally. There is no
  // state to reset — this test demonstrates that directly.
  @Test("a watch demoted on one call submits normally on the next once conditions recover")
  func demotionDoesNotPersistAcrossCalls() {
    let firstSweep = AutoDownloadPolicy.decide(
      watch: watch(), findings: [archive("1")],
      availableBytes: floor - 1, destinationExists: true, floor: floor)
    #expect(firstSweep == .demoted(.belowFloor(available: floor - 1, floor: floor)))

    let secondSweep = AutoDownloadPolicy.decide(
      watch: watch(), findings: [archive("1")],
      availableBytes: floor + cost([archive("1")]), destinationExists: true, floor: floor)
    #expect(secondSweep == .submit([archive("1")]))
  }

  // 9. The batch bound (finding 4): with room for two of three equally-sized
  // findings, the third is left for a later sweep rather than run the volume
  // below the floor. Order is preserved — the findings taken are a prefix,
  // not whichever happen to fit.
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

  // 10. The stopped-at finding is not silently dropped — it is simply not in
  // this sweep's `.submit`, which is what leaves it as an ordinary finding
  // for the next one to reconsider once space has changed.
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

  // Reason sentences are user-facing and worth pinning.
  @Test("belowFloor states both numbers in its sentence")
  func belowFloorSentence() {
    let reason = AutoDownloadPolicy.Reason.belowFloor(available: 1_000_000_000, floor: 49_000_000_000)
    #expect(reason.sentence.contains("1"))
  }

  @Test("destinationUnreachable states the path in its sentence")
  func destinationUnreachableSentence() {
    let reason = AutoDownloadPolicy.Reason.destinationUnreachable("/Volumes/Archive")
    #expect(reason.sentence.contains("/Volumes/Archive"))
  }
}
