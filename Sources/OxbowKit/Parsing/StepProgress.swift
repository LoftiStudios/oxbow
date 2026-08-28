/// Everything the UI needs to draw one row.
///
/// Every field is optional because the CLI emits four different status shapes
/// and not all of them carry every field. See the design spec, section 1.2.
public struct StepProgress: Codable, Sendable, Equatable {
  public var phase: String?
  public var fraction: Double?
  public var index: Int?
  public var total: Int?
  public var elapsed: Duration?
  public var remaining: Duration?
  /// FFmpeg's own encode rate, in multiples of realtime (its `speed=2.35x`
  /// field). Only `FFmpegProgressParser` ever fills this — the C# helper's
  /// status lines carry no equivalent. What tells a slow encode apart from a
  /// stalled one: a `remaining` that keeps climbing is ambiguous on its own,
  /// but paired with a `speed` near zero it means the encoder is genuinely
  /// crawling, not stuck.
  public var speed: Double?

  public init(
    phase: String? = nil,
    fraction: Double? = nil,
    index: Int? = nil,
    total: Int? = nil,
    elapsed: Duration? = nil,
    remaining: Duration? = nil,
    speed: Double? = nil)
  {
    self.phase = phase
    self.fraction = fraction
    self.index = index
    self.total = total
    self.elapsed = elapsed
    self.remaining = remaining
    self.speed = speed
  }
}
