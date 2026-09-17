import Foundation

/// Everything a step needs that is not part of the user's request: where to
/// work, where to write, and where the bundled FFmpeg lives.
public struct StepContext: Sendable {
  /// Passed as `--temp-path`. Owned by us and deleted when the step ends,
  /// because the CLI's own cleanup never runs when we kill it.
  public var stepTempDirectory: URL
  /// Where the CLI writes. Inside the job workspace, never the user's folder —
  /// the Swift parent moves the finished file out on success.
  public var outputFile: URL
  public var ffmpegPath: URL
  /// The artifacts of `dependsOn`, in the same order. A render consumes one;
  /// a composite consumes two, `[video, render]`.
  public var inputArtifacts: [URL]
  /// Resume timestamp, not frame index: Twitch timestamp seeks and trim=start_frame can select
  /// different frames. See docs/design/resume.md §2.1.
  public var resumeFrom: Duration?
  /// Optional chat-specific seek; nil uses the video seek. StepContextBuilder clamps shorter
  /// renders inside their endpoint so hstack has a final frame to repeat rather than silently
  /// truncating the delivery. See docs/design/resume.md §12.
  public var chatResumeFrom: Duration?
  /// Whether composite audio.m4a has a complete moov. False covers absent and interrupted
  /// sidecars; ArgumentBuilder rewrites either. StepContextBuilder performs the I/O check,
  /// keeping argv construction pure.
  public var hasUsableSidecar: Bool
  /// Optional captured helper log; argument-only contexts do not need one.
  public var log: StepLog?

  public init(
    stepTempDirectory: URL,
    outputFile: URL,
    ffmpegPath: URL,
    inputArtifacts: [URL] = [],
    resumeFrom: Duration? = nil,
    chatResumeFrom: Duration? = nil,
    hasUsableSidecar: Bool = false,
    log: StepLog? = nil)
  {
    self.stepTempDirectory = stepTempDirectory
    self.outputFile = outputFile
    self.ffmpegPath = ffmpegPath
    self.inputArtifacts = inputArtifacts
    self.resumeFrom = resumeFrom
    self.chatResumeFrom = chatResumeFrom
    self.hasUsableSidecar = hasUsableSidecar
    self.log = log
  }
}
