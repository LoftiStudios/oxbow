import Foundation

/// Numeric three-part release version; string ordering would place `0.2.10` before `0.2.9`.
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int

  /// Accepts `1.2.3` or `v1.2.3` for app versions and release tags. Rejects other forms; update
  /// checks suppress banners for unrecognized tags.
  public init?(_ string: String) {
    let withoutTagPrefix = string.hasPrefix("v") ? String(string.dropFirst()) : string

    // Keep empty components so malformed versions such as `1..3` are rejected.
    let parts = withoutTagPrefix.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }

    // Require ASCII digits: `Int` accepts signs, and `Character.isNumber` accepts non-ASCII
    // numbers.
    guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
          let major = Int(parts[0]),
          let minor = Int(parts[1]),
          let patch = Int(parts[2])
    else { return nil }

    self.major = major
    self.minor = minor
    self.patch = patch
  }

  public var description: String { "\(major).\(minor).\(patch)" }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}
