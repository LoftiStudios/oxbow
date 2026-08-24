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
  /// The artifact of `dependsOn`, if this step consumes one.
  public var inputArtifact: URL?

  public init(
    stepTempDirectory: URL,
    outputFile: URL,
    ffmpegPath: URL,
    inputArtifact: URL? = nil)
  {
    self.stepTempDirectory = stepTempDirectory
    self.outputFile = outputFile
    self.ffmpegPath = ffmpegPath
    self.inputArtifact = inputArtifact
  }
}
