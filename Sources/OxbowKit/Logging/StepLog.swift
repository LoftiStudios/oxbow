import Foundation

/// Per-step helper transcript on disk. Unlike unified logging, this keeps unredacted output
/// with app-controlled retention and direct access for bug reports.
public actor StepLog {

  /// Bound helper output to prevent logs growing indefinitely during long renders.
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
    // Use throwing write(contentsOf:); write(_:) may raise an uncaught Objective-C exception on
    // disk failure. Logging failure must not crash cleanup error handling.
    guard (try? handle.write(contentsOf: data)) != nil else { return }
    writtenBytes += data.count

    // Compact with headroom to avoid rewriting the file for every line over the cap.
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

  /// Keep the tail on whole-line boundaries so the first retained entry remains readable.
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
