import Foundation
@testable import OxbowKit

/// Actor-isolated parsed-output collector for concurrent callbacks.
actor CollectedOutput {
  private(set) var lines: [ParsedLine] = []

  func append(_ line: ParsedLine) {
    lines.append(line)
  }
}
