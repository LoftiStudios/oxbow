import Testing
@testable import OxbowKit

@Suite("Quality ladder")
struct QualityLadderTests {

  private func quality(_ name: String, _ resolution: String) -> StreamQuality {
    StreamQuality(name: name, resolution: resolution, bitsPerSecond: 1_000_000)
  }

  private var vod: [StreamQuality] {
    [quality("1080p60", "1920x1080"),
     quality("720p60", "1280x720"),
     quality("480p30", "852x480")]
  }

  // MARK: - Resolve

  /// "Best available" is the empty string, which is the behaviour proven
  /// against the real CLI: absent `-q` selects source.
  @Test func bestResolvesToTheEmptyString() {
    #expect(QualityLadder.resolve(.best, in: vod, forComposite: false) == "")
  }

  @Test func capPicksTheHighestRenditionAtOrBelowIt() {
    #expect(QualityLadder.resolve(.p720, in: vod, forComposite: false) == "720p60")
    #expect(QualityLadder.resolve(.p1080, in: vod, forComposite: false) == "1080p60")
    #expect(QualityLadder.resolve(.p480, in: vod, forComposite: false) == "480p30")
  }

  /// A video that only offers more than the cap should still download.
  @Test func fallsBackToTheLowestAvailableWhenNothingQualifies() {
    let onlyHigh = [quality("1080p60", "1920x1080")]
    #expect(QualityLadder.resolve(.p360, in: onlyHigh, forComposite: false) == "1080p60")
  }

  @Test func emptyListResolvesToTheEmptyString() {
    #expect(QualityLadder.resolve(.p720, in: [], forComposite: false) == "")
  }

  /// Spec §3.4. Resolution writes a concrete name into `quality`, and
  /// `compositeQuality` cannot tell a resolved name from a typed one — so a
  /// cap must never select a rendition the composite cannot size against.
  @Test func compositeResolutionSkipsUnparseableRenditions() {
    let mixed = [quality("720p0-1", ""), quality("480p30", "852x480")]
    #expect(QualityLadder.resolve(.p720, in: mixed, forComposite: true) == "480p30")
    #expect(QualityLadder.resolve(.p720, in: mixed, forComposite: false) == "480p30")
  }

  @Test func compositeFallbackAlsoSkipsUnparseableRenditions() {
    let mixed = [quality("720p0-1", ""), quality("1080p60", "1920x1080")]
    #expect(QualityLadder.resolve(.p360, in: mixed, forComposite: true) == "1080p60")
  }

  @Test func compositeResolutionYieldsNothingWhenNoRenditionParses() {
    #expect(QualityLadder.resolve(.p720, in: [quality("720p0-1", "")], forComposite: true) == "")
  }

  // MARK: - Bucket

  @Test func exactRenditionsBucketToTheirOwnRung() {
    #expect(QualityLadder.bucket(quality("1080p60", "1920x1080")) == .p1080)
    #expect(QualityLadder.bucket(quality("720p60", "1280x720")) == .p720)
    #expect(QualityLadder.bucket(quality("480p30", "852x480")) == .p480)
  }

  /// Spec §3.5. Rounding up would quietly raise the user's standing
  /// preference above anything they ever chose.
  @Test func oddRenditionsBucketDownwards() {
    #expect(QualityLadder.bucket(quality("900p30", "1600x900")) == .p720)
    #expect(QualityLadder.bucket(quality("1440p60", "2560x1440")) == .p1080)
  }

  @Test func belowTheLowestRungBucketsToTheLowestRung() {
    #expect(QualityLadder.bucket(quality("160p30", "284x160")) == .p360)
  }

  @Test func portraitBucketsByItsShortSide() {
    #expect(QualityLadder.bucket(quality("1080p60-Portrait", "1080x1920")) == .p1080)
  }

  /// Spec §3.7. Nothing to bucket, so the caller withholds quality from the
  /// save rather than guessing.
  @Test func aRenditionWithNoResolutionBucketsToNothing() {
    #expect(QualityLadder.bucket(quality("720p0-1", "")) == nil)
  }

  // MARK: - The documented non-round-trip

  /// Spec §3.3. resolve and bucket are not inverses, which is why
  /// `IntakeModel` keeps the cap rather than re-deriving it.
  @Test func resolveThenBucketCanRaiseTheCap() throws {
    let onlyHigh = [quality("1080p60", "1920x1080")]
    let resolved = QualityLadder.resolve(.p720, in: onlyHigh, forComposite: false)
    let rendition = try #require(onlyHigh.first { $0.name == resolved })
    #expect(QualityLadder.bucket(rendition) == .p1080)
  }
}
