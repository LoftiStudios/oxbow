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
  /// Where the helper's narrative output is kept. Optional because the
  /// argument builder — this type's other consumer — has no use for it and
  /// its tests construct contexts without one.
  public var log: StepLog?

  public init(
    stepTempDirectory: URL,
    outputFile: URL,
    ffmpegPath: URL,
    inputArtifacts: [URL] = [],
    log: StepLog? = nil)
  {
    self.stepTempDirectory = stepTempDirectory
    self.outputFile = outputFile
    self.ffmpegPath = ffmpegPath
    self.inputArtifacts = inputArtifacts
    self.log = log
  }
}
