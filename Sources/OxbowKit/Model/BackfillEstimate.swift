import Foundation

/// Rough backfill peak: sum delivered bytes plus the largest single-job transient overhead,
/// assuming serialized job cleanup. Price actual returned archives, never Twitch totalCount,
/// using nominal renditions because feed results lack qualities. Best assumes 1080p and can
/// underprice higher-resolution sources. Label estimates approximate; replace with real
/// StreamQuality estimates when available.
public struct BackfillEstimate: Equatable, Sendable {

  public let count: Int
  public let duration: Duration
  public let bytes: Int64

  public init(archives: [ChannelArchive], cap: QualityCap, output: DownloadOutput) {
    count = archives.count
    duration = archives.reduce(Duration.zero) { $0 + $1.duration }

    let quality = Self.nominalQuality(for: cap)
    // Built once, outside the loop: the geometry depends only on the nominal
    // quality, which is the same for every archive here.
    let geometry = output == .videoWithChat ? CompositeGeometry(quality: quality) : nil

    var deliveredTotal = Int64(0)
    var peakOverhead = Int64(0)
    for archive in archives {
      let estimate = SpaceEstimate(quality: quality, duration: archive.duration, composite: geometry)
      deliveredTotal += estimate.delivered
      peakOverhead = max(peakOverhead, estimate.total - estimate.delivered)
    }
    bytes = deliveredTotal + peakOverhead
  }

  /// Nominal cap-based rendition used only before per-video metadata is available; not a
  /// measured bitrate.
  private static func nominalQuality(for cap: QualityCap) -> StreamQuality {
    switch cap {
    case .best, .p1080:
      return StreamQuality(name: "1080p30", resolution: "1920x1080", bitsPerSecond: 6_000_000)
    case .p720:
      return StreamQuality(name: "720p30", resolution: "1280x720", bitsPerSecond: 3_500_000)
    case .p480:
      return StreamQuality(name: "480p30", resolution: "852x480", bitsPerSecond: 1_400_000)
    case .p360:
      return StreamQuality(name: "360p30", resolution: "640x360", bitsPerSecond: 700_000)
    }
  }
}
