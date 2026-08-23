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

  public init(
    phase: String? = nil,
    fraction: Double? = nil,
    index: Int? = nil,
    total: Int? = nil,
    elapsed: Duration? = nil,
    remaining: Duration? = nil)
  {
    self.phase = phase
    self.fraction = fraction
    self.index = index
    self.total = total
    self.elapsed = elapsed
    self.remaining = remaining
  }
}
