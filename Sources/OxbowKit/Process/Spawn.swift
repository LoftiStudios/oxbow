import Darwin
import Foundation

/// A running child process and its captured output streams.
public struct Spawn: @unchecked Sendable {
  public let pid: pid_t
  public let stdout: FileHandle
  public let stderr: FileHandle
}

public enum ProcessSpawner {

  /// Spawns `executable` in **its own process group**.
  ///
  /// The process group is the entire reason this exists rather than using
  /// Foundation's `Process`, which places the child in ours — making
  /// `kill(-pgid, …)` fatal to Oxbow itself.
  public static func spawn(
    executable: URL,
    arguments: [String],
    workingDirectory: URL)
    throws -> Spawn
  {
    var outPipe: [Int32] = [0, 0]
    var errPipe: [Int32] = [0, 0]
    guard pipe(&outPipe) == 0 else { throw SpawnError.pipeFailed(errno) }
    guard pipe(&errPipe) == 0 else {
      close(outPipe[0]); close(outPipe[1])
      throw SpawnError.pipeFailed(errno)
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }

    posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO)
    // The child must not retain either end beyond the dup2 targets, or the
    // read side never sees EOF and readDataToEndOfFile hangs forever.
    posix_spawn_file_actions_addclose(&actions, outPipe[0])
    posix_spawn_file_actions_addclose(&actions, outPipe[1])
    posix_spawn_file_actions_addclose(&actions, errPipe[0])
    posix_spawn_file_actions_addclose(&actions, errPipe[1])
    posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // pgroup 0 means "become your own group leader", so pgid == pid.
    posix_spawnattr_setpgroup(&attributes, 0)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))

    let argv: [UnsafeMutablePointer<CChar>?] =
      ([executable.path] + arguments).map { strdup($0) } + [nil]
    defer { for argument in argv where argument != nil { free(argument) } }

    var pid: pid_t = 0
    let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, environ)

    // Close our copies of the write ends, or we never observe EOF.
    close(outPipe[1])
    close(errPipe[1])

    guard result == 0 else {
      close(outPipe[0])
      close(errPipe[0])
      throw SpawnError.spawnFailed(code: result, message: String(cString: strerror(result)))
    }

    return Spawn(
      pid: pid,
      stdout: FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true),
      stderr: FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true))
  }

  /// Signals the child's whole process group. A negative pid means "group",
  /// and because we set pgroup 0 at spawn, the group id equals the child's pid.
  public static func signal(_ signalNumber: Int32, toGroupOf pid: pid_t) {
    kill(-pid, signalNumber)
  }

  /// Blocks until the child ends. Swift does not expose the `WIFEXITED` family
  /// of C macros, so the wait status is decoded by hand.
  public static func wait(_ pid: pid_t) -> ExitStatus {
    var raw: Int32 = 0
    while waitpid(pid, &raw, 0) == -1 && errno == EINTR { continue }

    let terminatingSignal = raw & 0x7F
    if terminatingSignal == 0 {
      return .exited((raw >> 8) & 0xFF)
    }
    return .signalled(terminatingSignal)
  }
}
