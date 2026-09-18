import Testing
@testable import OxbowKit

@Suite("Quality ladder")
struct QualityLadderTests {

  private func quality(_ name: String, _ resolution: String, bits: Int = 1_000_000) -> StreamQuality {
    StreamQuality(name: name, resolution: resolution, bitsPerSecond: bits)
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

  /// A saved cap must not resolve to a rendition unusable for composite geometry.
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

  // MARK: - Composite filter discriminator

  /// A dimension of 1 passes short-side parsing but rounds to zero in composite geometry.
  @Test func compositeResolutionSkipsARenditionGeometryRejects() {
    let odd = [quality("1x1080", "1x1080"), quality("1080p60", "1920x1080")]
    #expect(QualityLadder.resolve(.p360, in: odd, forComposite: true) == "1080p60")
    #expect(QualityLadder.resolve(.p360, in: odd, forComposite: false) == "1x1080")
  }

  // MARK: - Tie-breaking

  /// Equal short sides tie on bitrate, not orientation or list order.
  @Test func tieBreaksOnBitrateWhenShortSidesMatch() {
    let landscape = quality("1080p60", "1920x1080", bits: 8_000_000)
    let portrait = quality("1080p60-Portrait-1", "1080x1920", bits: 5_000_000)

    // Landscape first: should pick landscape (higher bitrate)
    let landscapeFirst = [landscape, portrait]
    #expect(QualityLadder.resolve(.p1080, in: landscapeFirst, forComposite: false) == "1080p60")

    // Portrait first: should still pick landscape (higher bitrate, not list order)
    let portraitFirst = [portrait, landscape]
    #expect(QualityLadder.resolve(.p1080, in: portraitFirst, forComposite: false) == "1080p60")
  }

  /// When both renditions have 0 bitrate (older clips), the tie-break
  /// degrades to first-listed, preserving the original list order.
  @Test func whenBitrateTiesAtZeroKeepsListOrder() {
    let a = quality("1080p60", "1920x1080", bits: 0)
    let b = quality("1080p60-Portrait-1", "1080x1920", bits: 0)

    // A first: should pick A
    #expect(QualityLadder.resolve(.p1080, in: [a, b], forComposite: false) == "1080p60")

    // B first: should pick B
    #expect(QualityLadder.resolve(.p1080, in: [b, a], forComposite: false) == "1080p60-Portrait-1")
  }

  /// Fallback chooses the highest bitrate at the smallest size above the cap; test unequal
  /// rates to exercise the reversed min comparator.
  @Test func fallbackPathAlsoTieBreaksOnBitrate() {
    let landscape = quality("1080p60", "1920x1080", bits: 8_000_000)
    let portrait = quality("1080p60-Portrait-1", "1080x1920", bits: 5_000_000)

    // Both have shortSide 1080, cap is .p720 (720 < 1080), so fallback fires.
    // Should pick landscape (higher bitrate) in both list orders.
    #expect(QualityLadder.resolve(.p720, in: [landscape, portrait], forComposite: false) == "1080p60")
    #expect(QualityLadder.resolve(.p720, in: [portrait, landscape], forComposite: false) == "1080p60")
  }

  // MARK: - Properties and coverage

  /// Every case of QualityCap has a label and a ceiling (or nil for .best).
  /// Driven off allCases so a new case forces failure.
  @Test func everyCapHasLabelAndCeiling() {
    let expectations: [QualityCap: (label: String, ceiling: Int?)] = [
      .best: ("Best available", nil),
      .p1080: ("Up to 1080p", 1080),
      .p720: ("Up to 720p", 720),
      .p480: ("Up to 480p", 480),
      .p360: ("Up to 360p", 360),
    ]

    #expect(expectations.count == QualityCap.allCases.count)
    for cap in QualityCap.allCases {
      if let (expectedLabel, expectedCeiling) = expectations[cap] {
        #expect(cap.label == expectedLabel)
        #expect(cap.ceiling == expectedCeiling)
      } else {
        #expect(Bool(false), "Missing expectation for \(cap)")
      }
    }
  }

  /// Literal persisted names catch renames that round-trip tests alone would miss.
  @Test func rawValuesArePersistedAndPinned() {
    for cap in QualityCap.allCases {
      #expect(QualityCap(rawValue: cap.rawValue) == cap)
    }
    #expect(QualityCap.best.rawValue == "best")
    #expect(QualityCap.p1080.rawValue == "p1080")
    #expect(QualityCap.p720.rawValue == "p720")
    #expect(QualityCap.p480.rawValue == "p480")
    #expect(QualityCap.p360.rawValue == "p360")
  }

  // MARK: - Unpinned behaviours

  /// An all-unparseable list on the non-composite path.
  @Test func allUnparseableListOnNonCompositeResolvesToEmpty() {
    let unparseable = [quality("720p0-1", "")]
    #expect(QualityLadder.resolve(.p720, in: unparseable, forComposite: false) == "")
  }

  /// Best always delegates to CLI via empty quality, regardless of composite filtering.
  @Test func bestReturnsEmptyStringRegardlessOfCompositeFilter() {
    let list = [quality("1080p60", "1920x1080")]
    #expect(QualityLadder.resolve(.best, in: list, forComposite: true) == "")
    #expect(QualityLadder.resolve(.best, in: list, forComposite: false) == "")
  }
}
