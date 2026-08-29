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

  /// The two strings being compared come from different places and are spelled
  /// differently: our git tags are `v0.2.1` (`.github/workflows/release.yml`
  /// triggers on `v*`), while `MARKETING_VERSION` — and therefore
  /// `CFBundleShortVersionString` — is a bare `0.2.1`. If the `v` did not come
  /// off, every comparison would be between a parsed value and nil.
  @Test func stripsTheLeadingVThatOnlyTagsCarry() throws {
    #expect(try #require(ReleaseVersion("v0.2.1")) == #require(ReleaseVersion("0.2.1")))
  }

  /// The reason this is a struct of three integers rather than a string
  /// comparison: `"0.2.10" < "0.2.9"` lexicographically, which would strand
  /// every user on .9 the moment a tenth patch shipped.
  @Test func ordersPatchesNumericallyRatherThanLexicographically() throws {
    #expect(try #require(ReleaseVersion("0.2.9")) < #require(ReleaseVersion("0.2.10")))
  }

  @Test func ordersMinorAheadOfPatch() throws {
    #expect(try #require(ReleaseVersion("0.2.99")) < #require(ReleaseVersion("0.3.0")))
  }

  @Test func ordersMajorAheadOfMinor() throws {
    #expect(try #require(ReleaseVersion("0.99.0")) < #require(ReleaseVersion("1.0.0")))
  }

  /// Anything that is not exactly three numbers is refused rather than
  /// guessed at. `UpdateCheck` turns a nil here into "no update", so a tag
  /// nobody anticipated makes the banner stay away — never makes it appear
  /// wrongly, and never crashes.
  @Test func refusesWhatItCannotParse() {
    #expect(ReleaseVersion("") == nil)
    #expect(ReleaseVersion("0.2") == nil)
    #expect(ReleaseVersion("0.2.1.4") == nil)
    #expect(ReleaseVersion("latest") == nil)
    #expect(ReleaseVersion("0.2.x") == nil)
    #expect(ReleaseVersion("v") == nil)
    #expect(ReleaseVersion("0.-2.1") == nil)
  }

  /// Prereleases are refused for the same reason, and it is not merely
  /// defensive: `/releases/latest` already excludes them, so a `1.0.0-beta.1`
  /// arriving here would mean something upstream of us had changed.
  @Test func refusesAPrereleaseSuffix() {
    #expect(ReleaseVersion("1.0.0-beta.1") == nil)
  }

  @Test func describesItselfWithoutTheTagPrefix() throws {
    #expect(try #require(ReleaseVersion("v1.2.3")).description == "1.2.3")
  }
}
