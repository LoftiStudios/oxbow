import Foundation
@testable import OxbowKit

/// Actor so a `HelperProcess` output callback can accumulate `ParsedLine`s
/// across concurrency domains in tests.
///
/// Named distinctly from the generic "Collected" so it doesn't claim that
/// name across the whole test target.
actor CollectedOutput {
  private(set) var lines: [ParsedLine] = []

  func append(_ line: ParsedLine) {
    lines.append(line)
  }
}
