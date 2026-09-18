import Foundation
import Testing
@testable import OxbowKit

@Suite("Update policy")
struct UpdatePolicyTests {

  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  // MARK: - When the automatic check runs

  @Test func checksOnAFirstEverLaunch() {
    #expect(UpdatePolicy.shouldCheckAutomatically(now: now, lastChecked: nil))
  }

  @Test func doesNotCheckAgainWithinTheInterval() {
    #expect(!UpdatePolicy.shouldCheckAutomatically(
      now: now, lastChecked: now.addingTimeInterval(-23 * 3600)))
  }

  @Test func checksOnceTheIntervalHasElapsed() {
    #expect(UpdatePolicy.shouldCheckAutomatically(
      now: now, lastChecked: now.addingTimeInterval(-25 * 3600)))
  }

  /// Future check dates must not suppress checks after clock rollback.
  @Test func checksWhenTheStoredDateIsInTheFuture() {
    #expect(UpdatePolicy.shouldCheckAutomatically(
      now: now, lastChecked: now.addingTimeInterval(3600)))
  }

  // MARK: - Whether a result is worth showing

  @Test func showsNothingWhenAlreadyCurrent() throws {
    #expect(!UpdatePolicy.shouldPresent(.upToDate, skipping: nil))
  }

  @Test func showsAnAvailableUpdateThatHasNotBeenSkipped() throws {
    #expect(UpdatePolicy.shouldPresent(try available("0.3.0"), skipping: nil))
  }

  @Test func staysHiddenForTheExactVersionThatWasSkipped() throws {
    #expect(!UpdatePolicy.shouldPresent(
      try available("0.3.0"), skipping: try #require(ReleaseVersion("0.3.0"))))
  }

  /// Dismissal suppresses only its exact version.
  @Test func reappearsForAVersionNewerThanTheSkippedOne() throws {
    #expect(UpdatePolicy.shouldPresent(
      try available("0.4.0"), skipping: try #require(ReleaseVersion("0.3.0"))))
  }

  private func available(_ version: String) throws -> UpdateCheck.Outcome {
    .available(
      try #require(ReleaseVersion(version)),
      try #require(URL(string: "https://github.com/LoftiStudios/oxbow/releases/tag/v\(version)")))
  }
}
