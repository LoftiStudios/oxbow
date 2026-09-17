import Foundation

/// Child process and output pipes. Drain stdout and stderr concurrently: a full undrained pipe
/// blocks the child, preventing exit and EOF on the other pipe.
public struct Spawn: @unchecked Sendable {
  public let pid: pid_t
  public let stdout: FileHandle
  public let stderr: FileHandle
}
