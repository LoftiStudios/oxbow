import Foundation

public struct JobID: Hashable, Codable, Sendable {
  public let rawValue: UUID
  public init(rawValue: UUID) { self.rawValue = rawValue }
}
