import Foundation

public struct StepID: Hashable, Codable, Sendable {
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
}
