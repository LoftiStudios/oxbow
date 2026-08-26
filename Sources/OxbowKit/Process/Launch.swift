import Foundation

/// One fully-resolved CLI invocation.
public struct Launch: Sendable {
  public var executable: URL
  public var arguments: [String]
  /// The step's temp directory. The CLI writes its ffmpeg log here.
  public var workingDirectory: URL
  /// Which text protocol this process speaks on stdout.
  public var dialect: OutputDialect

  public init(
    executable: URL,
    arguments: [String],
    workingDirectory: URL,
    dialect: OutputDialect = .helper)
  {
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.dialect = dialect
  }
}
