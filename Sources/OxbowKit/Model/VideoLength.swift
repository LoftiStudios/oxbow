import Foundation

/// Shared video-duration formatting for cards, rows, and Get Info.
public enum VideoLength {

  /// Uses `1:30` below an hour and `3:12:04` above it.
  public static func timecode(_ duration: Duration) -> String {
    duration.components.seconds >= 3600
      ? duration.formatted(.time(pattern: .hourMinuteSecond))
      : duration.formatted(.time(pattern: .minuteSecond))
  }
}
