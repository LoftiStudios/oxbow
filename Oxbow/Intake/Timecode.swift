import Foundation

/// Parses the trim times the user types.
///
/// Accepts `ss`, `mm:ss`, and `hh:mm:ss`, which is what people paste out of a
/// Twitch timestamp. Everything else is rejected rather than coerced: a
/// silently-misread trim produces a download of the wrong part of a VOD,
/// which looks like a successful job.
nonisolated enum Timecode {

  static func parse(_ text: String) -> Duration? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count <= 3 else { return nil }

    var total = 0
    for (index, part) in parts.enumerated() {
      // `Int(_:)` alone would accept "+5", " 5", and non-ASCII digits — and
      // returns nil for a run of digits too long for `Int`, which is the
      // first half of the overflow guard below.
      guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part)
      else { return nil }
      // Only the leading field may exceed 59: "90" is a minute and a half,
      // but "1:90" is not a time anybody means.
      if index > 0 && value > 59 { return nil }
      // Reported rather than trapping. Swift traps on integer overflow, so a
      // plain `total * 60 + value` turns a long number pasted into the trim
      // field into a crash — no privileged input required, just a text field
      // and a fat thumb. Too big to be a time is invalid input like any
      // other, and the sheet already refuses invalid input gracefully.
      let (scaled, didScaleOverflow) = total.multipliedReportingOverflow(by: 60)
      guard !didScaleOverflow else { return nil }
      let (sum, didSumOverflow) = scaled.addingReportingOverflow(value)
      guard !didSumOverflow else { return nil }
      total = sum
    }
    return .seconds(total)
  }

  /// An empty field means "no trim", which is valid. Anything else has to
  /// parse.
  static func isBlankOrValid(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespaces).isEmpty || parse(text) != nil
  }

  /// Zero-padded `hh:mm:ss`, which is what the timeline writes into the trim
  /// fields and therefore what `parse` above has to accept back.
  ///
  /// Hand-rolled rather than `duration.formatted(.time(pattern:))`, which
  /// produces `0:10:00` — a leading zero the fields would round-trip
  /// inconsistently, and a width the ruler's fixed-width label layout assumes
  /// away.
  static func format(_ duration: Duration) -> String {
    let total = max(0, duration.components.seconds)
    return [total / 3600, (total % 3600) / 60, total % 60]
      .map { String(format: "%02lld", $0) }
      .joined(separator: ":")
  }

  /// `00h 40m 00s` — the trim section's duration row. A readout, never parsed
  /// back, so it can afford to spell its units out where the fields above
  /// cannot: `hh:mm:ss` in a row the user cannot edit reads like a third
  /// field they are missing.
  static func spelled(_ duration: Duration) -> String {
    let total = max(0, duration.components.seconds)
    return zip([total / 3600, (total % 3600) / 60, total % 60], ["h", "m", "s"])
      .map { String(format: "%02lld", $0.0) + $0.1 }
      .joined(separator: " ")
  }
}
