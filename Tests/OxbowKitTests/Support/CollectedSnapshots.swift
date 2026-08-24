import Foundation
@testable import OxbowKit

/// Actor so a `QueueEngine.makeSnapshots()` observer can accumulate `[Job]`
/// snapshots across concurrency domains in tests.
///
/// Named distinctly from `CollectedOutput`, which accumulates `ParsedLine`s
/// instead — one type per file, and neither name should be reused for the
/// other's shape.
actor CollectedSnapshots {
  private(set) var count = 0

  func append(_ snapshot: [Job]) {
    count += 1
  }
}
