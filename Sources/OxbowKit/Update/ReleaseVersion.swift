import Foundation

/// A released version, as the three integers a semver tag actually orders by.
///
/// Three `Int`s rather than the string they came from, because the whole point
/// is the comparison and string comparison gets it wrong in the one place it
/// matters: `"0.2.10" < "0.2.9"` lexicographically, which would tell every
/// user on 0.2.9 they were current forever.
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int

  /// Parses `1.2.3` or `v1.2.3`, and nothing else.
  ///
  /// The `v` is optional because the two strings being compared are spelled
  /// differently at their sources: release tags are `v0.2.1` (`release.yml`
  /// triggers on `v*`) while `MARKETING_VERSION`, and so
  /// `CFBundleShortVersionString`, is a bare `0.2.1`.
  ///
  /// Everything else is refused rather than salvaged. `UpdateCheck` reads a
  /// nil as "no update", so an unexpected tag can only ever make the banner
  /// stay away — it cannot make one appear pointing at a version that does
  /// not exist.
  public init?(_ string: String) {
    let withoutTagPrefix = string.hasPrefix("v") ? String(string.dropFirst()) : string

    // `omittingEmptySubsequences: false` so `1..3` and a trailing dot are
    // seen as empty components and refused, rather than silently collapsing
    // into a shorter, well-formed-looking version.
    let parts = withoutTagPrefix.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }

    // Not `Int(_:)` alone: it accepts a leading `+` or `-`, so `0.-2.1` would
    // parse. Not `Character.isNumber` alone either — that is true of `½` and
    // of non-ASCII digits. ASCII digits are what a semver component is.
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
