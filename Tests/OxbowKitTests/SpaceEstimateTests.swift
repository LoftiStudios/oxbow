import Foundation
import Testing
@testable import OxbowKit

/// The estimator's job is not precision — `docs/design/disk-preflight.md` §3.2
/// is explicit that the composite term is a median of four samples spanning
/// 5.3x, and should be read as an order of magnitude rather than a number. Its
/// job is to land in the same order of magnitude as the measurements the design
/// was fitted to, and to scale correctly with geometry.
@Suite("Space estimate")
struct SpaceEstimateTests {

  private func quality(_ resolution: String, _ name: String, mbps: Double) -> StreamQuality {
    StreamQuality(name: name, resolution: resolution, bitsPerSecond: Int(mbps * 1_000_000))
  }

  private func gigabytes(_ bytes: Int64) -> Double { Double(bytes) / 1_000_000_000 }

  /// The three geometries in `composite-rate-control.md` §4.2, which are the
  /// only cross-geometry measurements of `-q:v 50` that exist. The pixel rates
  /// asserted here are that table's own "pixel rate" column — if these drift,
  /// the design doc's argument for scaling by bits-per-pixel no longer
  /// describes the code, because the constant was fitted against exactly these
  /// denominators.
  @Test(arguments: [
    (resolution: "1920x1080", name: "1080p60", expected: 147_744_000.0),
    (resolution: "1280x720", name: "720p60", expected: 65_664_000.0),
    (resolution: "1920x1080", name: "1080p30", expected: 73_872_000.0),
  ])
  func compositePixelRateMatchesTheMeasuredGeometries(
    _ testCase: (resolution: String, name: String, expected: Double)) throws
  {
    let source = quality(testCase.resolution, testCase.name, mbps: 8)
    let geometry = try #require(CompositeGeometry(quality: source))
    #expect(geometry.pixelRate == testCase.expected)
  }

  /// The worked example in `disk-preflight.md` §5: 23 GB of source, 10 GB of
  /// intermediate and 15 GB of composite for a six-hour 1080p60 job, 49 GB in
  /// total. The doc prints those figures; this is what keeps them true. If
  /// someone changes a constant, this is the number that moves and this is
  /// where they see what it cost.
  @Test func sixHoursAt1080p60MatchesTheWorkedExample() throws {
    let source = quality("1920x1080", "1080p60", mbps: 8.5)
    let geometry = try #require(CompositeGeometry(quality: source))
    let estimate = SpaceEstimate(
      quality: source, duration: .seconds(6 * 3600), composite: geometry)

    #expect(abs(gigabytes(estimate.source) - 23) < 1)
    #expect(abs(gigabytes(estimate.chatRender) - 10) < 1)
    #expect(abs(gigabytes(estimate.composite) - 15) < 1)
    #expect(abs(gigabytes(estimate.total) - 49) < 2)
  }

  /// The remedy line the intake offers has to be worth offering: dropping to
  /// 720p must produce a materially smaller number, not a rounding difference.
  @Test func sixHoursAt720p60IsMateriallySmaller() throws {
    let source = quality("1280x720", "720p60", mbps: 3.5)
    let geometry = try #require(CompositeGeometry(quality: source))
    let estimate = SpaceEstimate(
      quality: source, duration: .seconds(6 * 3600), composite: geometry)

    #expect(abs(gigabytes(estimate.total) - 27) < 2)
  }

  /// A plain download has no render and no composite. Stated because a
  /// non-zero term here would warn about bytes the job never writes.
  @Test func aPlainDownloadCountsOnlyItsSource() {
    let source = quality("1920x1080", "1080p60", mbps: 8.5)
    let estimate = SpaceEstimate(
      quality: source, duration: .seconds(3600), composite: nil)

    #expect(estimate.chatRender == 0)
    #expect(estimate.composite == 0)
    #expect(estimate.total == estimate.source)
  }

  /// What the destination volume needs on its own, which is not the total: the
  /// workspace holds the transient set while the destination receives one
  /// file. Getting this backwards would warn about the source's bytes landing
  /// somewhere they never land.
  @Test func deliveredIsTheCompositeWhenThereIsOneAndTheSourceOtherwise() throws {
    let source = quality("1920x1080", "1080p60", mbps: 8.5)
    let geometry = try #require(CompositeGeometry(quality: source))

    let composited = SpaceEstimate(
      quality: source, duration: .seconds(3600), composite: geometry)
    #expect(composited.delivered == composited.composite)

    let plain = SpaceEstimate(quality: source, duration: .seconds(3600), composite: nil)
    #expect(plain.delivered == plain.source)
  }

  /// A zero-length trim is reachable from the intake — drag both handles
  /// together — and must not produce a negative or nonsense figure.
  @Test func aZeroDurationEstimatesZero() throws {
    let source = quality("1920x1080", "1080p60", mbps: 8.5)
    let geometry = try #require(CompositeGeometry(quality: source))
    let estimate = SpaceEstimate(quality: source, duration: .seconds(0), composite: geometry)

    #expect(estimate.total == 0)
  }

  /// Defensive, because `Duration` is signed and the intake's two timecode
  /// fields can be crossed. A negative estimate would compare as "fits" against
  /// any free space at all, which is the wrong direction to fail in.
  @Test func aNegativeDurationEstimatesZeroRatherThanANegativeNumber() throws {
    let source = quality("1920x1080", "1080p60", mbps: 8.5)
    let geometry = try #require(CompositeGeometry(quality: source))
    let estimate = SpaceEstimate(quality: source, duration: .seconds(-60), composite: geometry)

    #expect(estimate.source == 0)
    #expect(estimate.chatRender == 0)
    #expect(estimate.composite == 0)
    #expect(estimate.total == 0)
  }
}
