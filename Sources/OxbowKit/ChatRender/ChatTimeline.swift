import Foundation

/// When each comment appears, and which frame shows what: the CLI's timeline, reproduced down
/// to its floating-point rounding. Line references are to `ChatRenderer.cs` at the pinned
/// commit.
///
/// Keep the arithmetic in the CLI's own expressions. `floor(x / 0.2) * 0.2` is not a multiple
/// of 0.2 — `3 * 0.2` is `0.6000000000000001` — and comparing it against `tick / 30.0` puts
/// about a third of comments one update later than exact arithmetic would. Tidier arithmetic
/// would be more correct and would not match.
struct ChatTimeline: Sendable {
  let framerate: Int
  /// Frames between redraws; positions change only on these (CRO:35).
  let updateFrame: Int
  /// Absolute VOD time × framerate of output frame 0 (CR:2145-2146).
  let startTick: Int
  let frameCount: Int
  /// Each comment's display time after dispersion and flooring, in list order — which is the
  /// order the CLI draws in; it never sorts.
  let offsets: [Double]
  /// `offsets` with each entry raised to the largest before it. The CLI finds the newest
  /// comment by scanning forward and stopping at the first one not yet due, so a comment is
  /// visible only once every comment before it is — the longest prefix all due by `t`.
  private let prefixMaximum: [Double]

  init(document: ChatDocument, framerate: Int, updateRate: Double = 0.2, disperses: Bool = true) {
    self.framerate = framerate
    updateFrame = max(1, Int(updateRate * Double(framerate)))
    startTick = Int(document.video.start.rounded(.down)) * framerate
    frameCount = max(Int((document.video.end * Double(framerate)).rounded(.up)) - startTick, 0)

    var offsets = document.comments.map(\.contentOffsetSeconds)
    if disperses {
      Self.disperse(&offsets, createdAt: document.comments.map(\.createdAtTicks))
    }
    Self.floor(&offsets, updateRate: updateRate)
    self.offsets = offsets

    var running = -Double.infinity
    prefixMaximum = offsets.map { offset in
      running = max(running, offset)
      return running
    }
  }

  var duration: Duration {
    .seconds(Double(frameCount) / Double(framerate))
  }

  /// The time of the redraw output frame `index` shows (CR:379-388, 718).
  func updateTime(forFrame index: Int) -> Double {
    let tick = startTick + index
    let update = tick - tick % updateFrame
    return Double(update) / Double(framerate)
  }

  /// The index of the newest comment shown at `time`, or -1 if none is. Inclusive: a comment
  /// due exactly at `time` is shown (CR:702-714, strict `>`).
  func newestIndex(at time: Double) -> Int {
    var low = 0
    var high = prefixMaximum.count
    while low < high {
      let middle = (low + high) / 2
      if prefixMaximum[middle] <= time { low = middle + 1 } else { high = middle }
    }
    return low - 1
  }

  /// CR:208-244. Recovers sub-second timing lost to Twitch's whole-second offsets, from
  /// `created_at` when the file's clock is consistent and from seeded jitter when it is not.
  private static func disperse(_ offsets: inout [Double], createdAt: [Int64]) {
    // A single fractional offset means an old chat with real timing: leave all of it alone.
    guard !offsets.contains(where: { $0.truncatingRemainder(dividingBy: 1) != 0 }) else { return }
    guard !offsets.isEmpty else { return }

    let ticksPerSecond: Int64 = 10_000_000
    let estimates = zip(createdAt, offsets).map { created, offset in
      created - Int64(offset) * ticksPerSecond
    }
    let earliest = estimates.min() ?? 0
    let latest = estimates.max() ?? 0

    if Double(latest - earliest) / Double(ticksPerSecond) < 1.5 {
      // Later only, never earlier, and never re-sorted.
      offsets = createdAt.map { Double($0 - earliest) / Double(ticksPerSecond) }
    } else {
      jitter(&offsets)
    }
  }

  /// CR:254-288, ported from the code rather than its doc comment: in a run of equal whole
  /// seconds the first two comments stay on the second, and a run of two is untouched.
  private static func jitter(_ offsets: inout [Double]) {
    var random = DotNetRandom(seed: Int32(truncatingIfNeeded: offsets.count))
    var i = 0
    while i < offsets.count - 1 {
      defer { i += 1 }
      guard offsets[i + 1] == offsets[i], offsets[i].truncatingRemainder(dividingBy: 1) == 0
      else { continue }

      let startIndex = i + 1
      while i < offsets.count - 1, offsets[i + 1] == offsets[i] {
        i += 1
      }

      var scaleFactor = 1.0
      if i < offsets.count - 1, offsets[i + 1] - offsets[i] < 1 {
        scaleFactor = offsets[i + 1] - offsets[i]
      }

      let toUpdate = i - startIndex
      guard toUpdate >= 1 else { continue }
      for c in 1...toUpdate {
        let jitter = random.nextDouble() * 0.98 - 0.49
        let distributed = (Double(c) + jitter) / Double(toUpdate + 1)
        offsets[startIndex + c] += distributed * scaleFactor
      }
    }
  }

  /// CR:293-309.
  private static func floor(_ offsets: inout [Double], updateRate: Double) {
    guard updateRate > 0 else { return }
    for index in offsets.indices {
      offsets[index] = if updateRate > 1 {
        offsets[index].rounded(.down)
      } else {
        (offsets[index] / updateRate).rounded(.down) * updateRate
      }
    }
  }
}
