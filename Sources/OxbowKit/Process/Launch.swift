import Foundation

/// One fully-resolved CLI invocation.
public struct Launch: Sendable {
  public var executable: URL
  public var arguments: [String]
  /// The step's temp directory. The CLI writes its ffmpeg log here.
  public var workingDirectory: URL

  public init(executable: URL, arguments: [String], workingDirectory: URL) {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
  }
}
