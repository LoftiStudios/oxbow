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
  /// Bytes the encoder has written so far, from FFmpeg's `total_size`.
  ///
  /// The only signal for how large a composite is becoming. `.composite` asks
  /// for a quality rather than a bitrate, so the size is not knowable in
  /// advance, and `docs/design/composite-rate-control.md` §7.1 shows it cannot
  /// be capped — `-maxrate` displaces quality targeting rather than bounding
  /// it. Bytes over fraction is the projection that lets a runaway encode
  /// announce itself instead of silently filling a disk.
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
  /// Where this step's output is heading, in bytes.
  ///
  /// `bytesWritten / fraction`. Under a quality target the composite's size is
  /// not knowable before the encode runs, and
  /// `docs/design/composite-rate-control.md` §7.1 shows it cannot be bounded
  /// either — `-maxrate` displaces quality targeting rather than capping it.
  /// So this is the mechanism by which an unexpected job announces itself
  /// while there is still time to cancel it.
  ///
  /// Withheld below 2% complete. The opening blocks are I-frames over a tiny
  /// denominator, so an early projection is not merely imprecise — it is a
  /// large number that then visibly collapses, which reads as a broken
  /// estimate rather than a converging one.
  public var projectedBytes: Int? {
    guard let bytesWritten, let fraction, fraction >= 0.02 else { return nil }
    return Int(Double(bytesWritten) / fraction)
  }

}
