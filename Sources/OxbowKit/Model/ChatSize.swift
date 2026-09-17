import Foundation

/// Resolution-relative chat size mapped by CompositeGeometry. Raw values are persisted
/// preferences; renaming cases requires a storage migration.
public enum ChatSize: String, Codable, CaseIterable, Sendable {
  case small
  case medium
  case large

  public static let `default`: ChatSize = .medium
}
