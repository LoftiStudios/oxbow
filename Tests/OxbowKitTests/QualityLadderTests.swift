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

  // MARK: - Composite filter discriminator

  /// The one input where the composite filter actually bites: a rendition
  /// with a dimension of 1 has a `shortSide` (so `sized` keeps it) but no
  /// usable `CompositeGeometry` (so a composite must not select it).
  @Test func compositeResolutionSkipsARenditionGeometryRejects() {
    let odd = [quality("1x1080", "1x1080"), quality("1080p60", "1920x1080")]
    #expect(QualityLadder.resolve(.p360, in: odd, forComposite: true) == "1080p60")
    #expect(QualityLadder.resolve(.p360, in: odd, forComposite: false) == "1x1080")
  }

  // MARK: - Tie-breaking

  /// When two renditions have the same shortSide, resolve picks the one
  /// with higher bitrate. A vertical VOD can carry both landscape
  /// (1920x1080, shortSide=1080) and portrait (1080x1920, shortSide=1080)
  /// — both have the exact same shortSide. The tie-break is on bitrate, not
  /// orientation, and it must hold regardless of list order.
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

  /// The fallback path (when ceiling is not met) also ties on bitrate, and
  /// the comparison must be inverted for `min` to surface the higher bitrate.
  /// This test reaches the fallback with unequal nonzero bitrates: a cap that
  /// sits below both renditions' shared short side.
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

  /// Stored in preferences, so the wire names are load-bearing. Driving the
  /// round trip off `allCases` catches a new case automatically; the literal
  /// strings are what actually catch a rename — a loop alone would round-trip
  /// happily even after one.
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

  /// `.best` returns empty string regardless of whether the list is parsed or
  /// filtered. Worth pinning because `.best` is the one place a reader might
  /// expect the composite filter to matter, and it does not — the empty string
  /// is the same whether we filtered or not.
  @Test func bestReturnsEmptyStringRegardlessOfCompositeFilter() {
    let list = [quality("1080p60", "1920x1080")]
    #expect(QualityLadder.resolve(.best, in: list, forComposite: true) == "")
    #expect(QualityLadder.resolve(.best, in: list, forComposite: false) == "")
  }
}
