/// Optional progress fields accommodate the CLI's different status-line shapes.
public struct StepProgress: Codable, Sendable, Equatable {
  public var phase: String?
  public var fraction: Double?
  public var index: Int?
  public var total: Int?
  public var elapsed: Duration?
  public var remaining: Duration?
  /// FFmpeg speed in multiples of realtime. Absent for CLI status output; helps distinguish
  /// slow encoding from a stall.
  public var speed: Double?
  /// FFmpeg `total_size`, used to project output size while quality-targeted encoding runs.
  public var bytesWritten: Int?

  public init(
    phase: String? = nil,
    fraction: Double? = nil,
    index: Int? = nil,
    total: Int? = nil,
    elapsed: Duration? = nil,
    remaining: Duration? = nil,
    speed: Double? = nil,
    bytesWritten: Int? = nil)
  {
    self.phase = phase
    self.fraction = fraction
    self.index = index
    self.total = total
    self.elapsed = elapsed
    self.remaining = remaining
    self.speed = speed
    self.bytesWritten = bytesWritten
  }
  /// Projected final bytes (`bytesWritten / fraction`). Withheld below 2% because early
  /// I-frames over a tiny denominator produce unstable estimates.
  public var projectedBytes: Int? {
    guard let bytesWritten, let fraction, fraction >= 0.02 else { return nil }
    return Int(Double(bytesWritten) / fraction)
  }

}
