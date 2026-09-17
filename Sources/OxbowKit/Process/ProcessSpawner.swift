import Darwin
import Foundation

public enum ProcessSpawner {

  /// Spawns a separate process group so cancellation can signal the helper and its children
  /// without signalling Oxbow.
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

    // Reset inherited signal masks and dispositions. Blocked SIGCHLD prevents CoreCLR from
    // reaping FFmpeg, hanging `WaitForExit` after output is complete.
    var emptyMask = sigset_t()
    sigemptyset(&emptyMask)
    posix_spawnattr_setsigmask(&attributes, &emptyMask)

    var allSignals = sigset_t()
    sigfillset(&allSignals)
    posix_spawnattr_setsigdefault(&attributes, &allSignals)

    posix_spawnattr_setflags(
      &attributes,
      Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

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

  /// Signals the child's process group (`pgid == pid`). Refuse PIDs ≤1: zero signals our group
  /// and -1 signals all permitted processes. Returns 0 on success, -1 for refused PID, or errno
  /// from `kill`.
  @discardableResult
  public static func signal(_ signalNumber: Int32, toGroupOf pid: pid_t) -> Int32 {
    guard pid > 1 else { return -1 }
    guard kill(-pid, signalNumber) == 0 else { return errno }
    return 0
  }

  /// Blocks until the child ends. Swift does not expose the `WIFEXITED`
  /// family of C macros, so the wait status is decoded by hand.
  public static func wait(_ pid: pid_t) -> ProcessExitStatus {
    var raw: Int32 = 0
    var result: pid_t = 0
    var waitErrno: Int32 = 0
    repeat {
      result = waitpid(pid, &raw, 0)
      waitErrno = errno
    } while result == -1 && waitErrno == EINTR

    guard result != -1 else {
      // Retry EINTR only; other wait failures mean unknown status, never successful exit.
      return .waitFailed(errno: waitErrno)
    }

    let terminatingSignal = raw & 0x7F
    if terminatingSignal == 0 {
      return .exited((raw >> 8) & 0xFF)
    }
    return .signalled(terminatingSignal)
  }
}
