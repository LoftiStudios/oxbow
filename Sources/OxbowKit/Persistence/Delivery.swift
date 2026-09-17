import Foundation

/// Moves completed files out of the workspace without unintended overwrites. Injected
/// filesystem operations let tests exercise destination races.
enum Delivery {

  /// Moves to the first free name and returns it. Retry name collisions because another writer
  /// can occupy a checked path; `moveItem` refuses to overwrite. Rethrow other failures, such
  /// as a full disk or read-only folder.
  static func moveWithoutReplacing(
    _ file: URL,
    to destination: URL,
    exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
    move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) })
    throws -> URL
  {
    while true {
      // Always step from the original destination to avoid names such as `out (2) (2).mp4`.
      let candidate = OutputNaming.availableURL(for: destination, exists: exists)
      do {
        try move(file, candidate)
        return candidate
      } catch let error as NSError
        where error.domain == NSCocoaErrorDomain
        && error.code == NSFileWriteFileExistsError
      {
        continue
      }
    }
  }
}
