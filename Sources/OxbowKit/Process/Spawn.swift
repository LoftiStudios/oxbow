import Foundation

/// A running child process and its captured output streams.
///
/// - Important: `stdout` and `stderr` must be drained **concurrently**, not
///   one after the other. macOS pipe buffers are 16 KB (growing to 64 KB). A
///   child that writes more than that to the stream nobody is draining blocks
///   inside `write(2)` — so it never exits, so it never closes the other
///   pipe's write end, so `readDataToEndOfFile()` on that other stream never
///   returns. FFmpeg writes its entire progress stream to stderr, so this is
///   not a theoretical concern for this app: drain both from separate tasks.
public struct Spawn: @unchecked Sendable {
  public let pid: pid_t
  public let stdout: FileHandle
  public let stderr: FileHandle
}
