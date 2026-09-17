import Foundation
@testable import OxbowKit

/// Actor-isolated queue-snapshot collector.
actor CollectedSnapshots {
  private(set) var count = 0

  func append(_ snapshot: [Job]) {
    count += 1
  }
}
