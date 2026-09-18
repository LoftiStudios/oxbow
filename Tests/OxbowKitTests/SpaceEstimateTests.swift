import Foundation
import Testing
@testable import OxbowKit

/// Check measured order of magnitude and geometry scaling; content variation makes this an
/// advisory estimate.
@Suite("Space estimate")
struct SpaceEstimateTests {

  private func quality(_ resolution: String, _ name: String, mbps: Double) -> StreamQuality {
    StreamQuality(name: name, resolution: resolution, bitsPerSecond: Int(mbps * 1_000_000))
  }

  private func gigabytes(_ bytes: Int64) -> Double { Double(bytes) / 1_000_000_000 }

  /// Pin the pixel-rate denominators used to fit the three measured geometries in
  /// `composite-rate-control.md` §4.2.
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

  /// Pins `disk-preflight.md` §5's six-hour example: approximately 23 GB source, 10 GB chat, 15
  /// GB composite, 49 GB total.
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

  /// Destination need is delivered size, distinct from workspace peak.
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

  /// Crossed trim fields must not produce negative estimates.
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
