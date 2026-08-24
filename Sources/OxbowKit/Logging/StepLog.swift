import Foundation

/// The helper's narrative output for one step, kept on disk.
///
/// The parser turns the helper's stdout into `ParsedLine`s, of which only
/// `.status` drives the UI. The rest — `.log` and `.ffmpeg` — used to be
/// dropped on the floor, which is why a helper that finished its work and
/// then hung could only be diagnosed by sampling the process: the app had
/// captured what it was saying and thrown it away.
///
/// Deliberately a file rather than Apple's unified logging. `os_log` is the
/// right tool for the app's own diagnostics, but not for this: it redacts
/// dynamic strings unless every interpolation is marked public, its retention
/// is the system's to decide rather than ours, and it is one global stream
/// that would have to be queried and re-filtered per step. What a user needs
/// here is this step's transcript, attached to this row, copyable into a bug
/// report.
public actor StepLog {

  /// Bounded because a long chat render emits enormous output, and an
  /// unbounded log would happily sit next to an 8 GB video eating disk.
  public static let defaultMaxBytes = 256 * 1024

  private let fileURL: URL
  private let maxBytes: Int
  private var handle: FileHandle?
  private var writtenBytes = 0

  public init(fileURL: URL, maxBytes: Int = StepLog.defaultMaxBytes) {
    self.fileURL = fileURL
    self.maxBytes = maxBytes
  }

  public func append(_ line: String) {
    guard let data = "\(line)\n".data(using: .utf8) else { return }

    guard let handle = openHandle() else { return }
    handle.write(data)
    writtenBytes += data.count

    // Compact only when meaningfully over, not on every line past the cap:
    // rewriting the file per line would turn a chatty render into O(n^2) I/O.
    if writtenBytes > maxBytes + maxBytes / 2 { compact() }
  }

  /// The most recent output, whole lines only.
  ///
  /// - Parameter lines: how many trailing lines to return; `nil` for whatever
  ///   the cap currently holds.
  public func tail(lines: Int? = nil) -> String {
    guard let data = try? Data(contentsOf: fileURL) else { return "" }
    let text = String(decoding: data, as: UTF8.self)
    guard let lines else { return text }

    let recent = text.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.isEmpty }
      .suffix(lines)
    guard !recent.isEmpty else { return "" }
    return recent.joined(separator: "\n") + "\n"
  }

  /// Closes the file. Appending after this reopens it.
  public func close() {
    try? handle?.close()
    handle = nil
  }

  deinit { try? handle?.close() }

  private func openHandle() -> FileHandle? {
    if let handle { return handle }

    let directory = fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: fileURL.path) {
      FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }

    guard let opened = try? FileHandle(forWritingTo: fileURL) else { return nil }
    let end = (try? opened.seekToEnd()) ?? 0
    writtenBytes = Int(end)
    handle = opened
    return opened
  }

  /// Rewrites the file keeping its tail.
  ///
  /// Drops whole lines, never a byte offset: cutting mid-line would leave a
  /// mangled first entry like "ne 47", which reads as corruption to whoever
  /// opens the log looking for what went wrong.
  private func compact() {
    guard let data = try? Data(contentsOf: fileURL) else { return }
    let text = String(decoding: data, as: UTF8.self)

    var kept = Substring(text)
    while kept.utf8.count > maxBytes, let newline = kept.firstIndex(of: "\n") {
      kept = kept[kept.index(after: newline)...]
    }

    close()
    try? Data(kept.utf8).write(to: fileURL, options: .atomic)
    writtenBytes = kept.utf8.count
  }
}
