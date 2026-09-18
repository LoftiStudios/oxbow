import Foundation

/// Strictly parse ss, mm:ss, or hh:mm:ss trim times.
nonisolated enum Timecode {

  static func parse(_ text: String) -> Duration? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count <= 3 else { return nil }

    var total = 0
    for (index, part) in parts.enumerated() {
      // Require ASCII digits explicitly and reject values too large for Int.
      guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part)
      else { return nil }
      // Only the leading field may exceed 59.
      if index > 0 && value > 59 { return nil }
      // Treat arithmetic overflow as invalid input instead of trapping on pasted text.
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

  /// Zero-padded hh:mm:ss for field round-tripping and fixed-width timeline labels.
  static func format(_ duration: Duration) -> String {
    let total = max(0, duration.components.seconds)
    return [total / 3600, (total % 3600) / 60, total % 60]
      .map { String(format: "%02lld", $0) }
      .joined(separator: ":")
  }

  /// Duration readout with explicit units to distinguish it from editable time fields.
  static func spelled(_ duration: Duration) -> String {
    let total = max(0, duration.components.seconds)
    return zip([total / 3600, (total % 3600) / 60, total % 60], ["h", "m", "s"])
      .map { String(format: "%02lld", $0.0) + $0.1 }
      .joined(separator: " ")
  }
}
