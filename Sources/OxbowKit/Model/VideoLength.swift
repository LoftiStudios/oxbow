import Foundation

/// How long a video is, written the way a video player writes it.
///
/// **One definition, because there were about to be three.** `JobInfo` and
/// `VideoCard` each carried their own private copy of this — identical
/// arithmetic, identical reasoning in the comment, different function names —
/// and the Watching row needed a third. Two copies is a coincidence; three is
/// a pattern that will drift, and the first divergence would be a duration
/// that reads one way in Get Info and another beside the same video's row.
public enum VideoLength {

  /// `1:30` under an hour, `3:12:04` over it.
  ///
  /// The hour field is dropped below an hour rather than shown as a leading
  /// `0:`, which is the shape every video player uses and the one nobody has
  /// to parse.
  public static func timecode(_ duration: Duration) -> String {
    duration.components.seconds >= 3600
      ? duration.formatted(.time(pattern: .hourMinuteSecond))
      : duration.formatted(.time(pattern: .minuteSecond))
  }
}
