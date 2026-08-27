import Foundation

/// Stacks a finished video and a finished chat render into one file.
///
/// Carries no geometry: `hstack` derives every dimension from its inputs, and
/// refuses unequal heights outright — which is the point. A mismatch fails in
/// about a second with a zero-byte output rather than producing a subtly wrong
/// 22 GB file. See `docs/design/compositing.md` §5.
public struct CompositeRequest: Codable, Sendable, Equatable {
  /// The **video's** framerate. The chat is normalised up to it before the
  /// stack, so a non-harmonic pair cannot produce a variable-framerate output.
  public var framerate: Int
  public var bitrateMbps: Int
  /// Only so `FFmpegProgressParser` can turn `out_time_us` into a fraction.
  /// Known from `VideoInfo` at intake; FFmpeg's own progress output never
  /// reports a total.
  public var duration: Duration
  public var destination: URL

  public init(framerate: Int, bitrateMbps: Int, duration: Duration, destination: URL) {
    self.framerate = framerate
    self.bitrateMbps = bitrateMbps
    self.duration = duration
    self.destination = destination
  }
}

extension CompositeRequest {
  /// A missing input is a wiring bug, not user input. An empty path makes
  /// FFmpeg fail immediately and loudly rather than silently compositing
  /// something unintended.
  func inputPath(_ context: StepContext, at index: Int) -> String {
    context.inputArtifacts.indices.contains(index)
      ? context.inputArtifacts[index].path
      : ""
  }

  /// `-ss` for a resume point, or nothing on a first attempt. Applied before
  /// each `-i` — an input seek, not a filter — because input and output seek
  /// agree exactly on Twitch sources where frame-index trimming does not.
  /// See docs/design/resume.md §2.1.
  func resumeSeek(_ from: Duration?) -> [String] {
    guard let from else { return [] }
    let seconds = Double(from.components.seconds)
      + Double(from.components.attoseconds) / 1e18
    return ["-ss", String(format: "%.6f", seconds)]
  }
}
