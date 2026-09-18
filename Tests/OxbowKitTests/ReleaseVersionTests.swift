import Foundation
import Testing
@testable import OxbowKit

@Suite("Release version")
struct ReleaseVersionTests {

  @Test func parsesMajorMinorPatch() throws {
    let version = try #require(ReleaseVersion("1.2.3"))
    #expect(version.major == 1)
    #expect(version.minor == 2)
    #expect(version.patch == 3)
  }

  /// Compare prefixed release tags with bare marketing versions.
  @Test func stripsTheLeadingVThatOnlyTagsCarry() throws {
    #expect(try #require(ReleaseVersion("v0.2.1")) == #require(ReleaseVersion("0.2.1")))
  }

  /// Numeric comparison must order patch 10 after patch 9.
  @Test func ordersPatchesNumericallyRatherThanLexicographically() throws {
    #expect(try #require(ReleaseVersion("0.2.9")) < #require(ReleaseVersion("0.2.10")))
  }

  @Test func ordersMinorAheadOfPatch() throws {
    #expect(try #require(ReleaseVersion("0.2.99")) < #require(ReleaseVersion("0.3.0")))
  }

  @Test func ordersMajorAheadOfMinor() throws {
    #expect(try #require(ReleaseVersion("0.99.0")) < #require(ReleaseVersion("1.0.0")))
  }

  /// Reject malformed versions without crashing or inventing an update.
  @Test func refusesWhatItCannotParse() {
    #expect(ReleaseVersion("") == nil)
    #expect(ReleaseVersion("0.2") == nil)
    #expect(ReleaseVersion("0.2.1.4") == nil)
    #expect(ReleaseVersion("latest") == nil)
    #expect(ReleaseVersion("0.2.x") == nil)
    #expect(ReleaseVersion("v") == nil)
    #expect(ReleaseVersion("0.-2.1") == nil)
  }

  /// Prereleases remain unsupported, matching the latest-release endpoint.
  @Test func refusesAPrereleaseSuffix() {
    #expect(ReleaseVersion("1.0.0-beta.1") == nil)
  }

  @Test func describesItselfWithoutTheTagPrefix() throws {
    #expect(try #require(ReleaseVersion("v1.2.3")).description == "1.2.3")
  }
}
