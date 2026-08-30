import Foundation

/// Getting a finished file out of the workspace and into the user's folder
/// without ever destroying what it finds there.
///
/// Separate from `QueueEngine` because the interesting behaviour is the
/// filesystem race, and provoking that through the engine would mean
/// injecting `FileManager` into it. The seam is here instead: `exists` and
/// `move` default to the real thing, and tests substitute both — the same
/// shape `OutputNaming.availableURL` and `IntakeModel.fileExists` already
/// use.
enum Delivery {

  /// Moves `file` to `destination`, or to the first free name after it,
  /// overwriting nothing. Returns where it landed.
  ///
  /// Retries rather than trusting the name it picked. That name was free
  /// when it was chosen, and this runs against a user's live Downloads
  /// folder — the gap between the check and the move belongs to whatever
  /// else is writing there. Losing the race costs a second attempt instead
  /// of failing a job whose download already succeeded.
  ///
  /// `move` is used precisely because `FileManager.moveItem` *fails* on an
  /// occupied destination rather than replacing it, which is what makes the
  /// retry safe: the check and the move cannot disagree about a file that
  /// appears between them. Any error that is not "something is already
  /// there" is rethrown at once — a full disk or a read-only folder must
  /// surface as a move failure, not spin through candidate names.
  static func moveWithoutReplacing(
    _ file: URL,
    to destination: URL,
    exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
    move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) })
    throws -> URL
  {
    while true {
      // Always stepped from `destination`, never from the previous
      // candidate: re-stepping `out (2).mp4` yields `out (2) (2).mp4`, which
      // reads as a duplicate of a duplicate and is not the next free name at
      // all. `availableURL` counts from the original every time.
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
