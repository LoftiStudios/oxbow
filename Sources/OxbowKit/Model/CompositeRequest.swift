import Foundation

/// Composite inputs with hstack, which derives geometry and rejects unequal heights. See
/// docs/design/compositing.md §5.
public struct CompositeRequest: Codable, Sendable, Equatable {
  /// The **video's** framerate. The chat is normalised up to it before the
  /// stack, so a non-harmonic pair cannot produce a variable-framerate output.
  public var framerate: Int
  /// Effective video duration for progress fractions; FFmpeg does not report a total.
  public var duration: Duration
  public var destination: URL

  public init(framerate: Int, duration: Duration, destination: URL) {
    self.framerate = framerate
    self.duration = duration
    self.destination = destination
  }
}

extension CompositeRequest {
  /// Missing inputs are wiring errors; an empty path forces immediate failure.
  func inputPath(_ context: StepContext, at index: Int) -> String {
    context.inputArtifacts.indices.contains(index)
      ? context.inputArtifacts[index].path
      : ""
  }

  /// Timestamp input seek before -i. Frame-index trimming disagrees on Twitch sources; see
  /// docs/design/resume.md §2.1.
  func resumeSeek(_ from: Duration?) -> [String] {
    guard let from else { return [] }
    let seconds = Double(from.components.seconds)
      + Double(from.components.attoseconds) / 1e18
    return ["-ss", String(format: "%.6f", seconds)]
  }
}
