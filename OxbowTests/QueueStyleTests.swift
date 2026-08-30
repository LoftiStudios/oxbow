import SwiftUI
import Testing
@testable import Oxbow

@Suite("Queue style")
struct QueueStyleTests {

  /// Two greys, not one. `.pending` and `.neutral` exist to separate a step
  /// that is going to run from one that never will, and that separation is
  /// only real if the colours actually differ — a tone hierarchy that paints
  /// the same pixel twice is a comment, not a design.
  @Test func pendingAndInertAreDifferentGreys() {
    for scheme in [ColorScheme.light, .dark] {
      #expect(
        JobPresentation.Tone.pending.color(for: scheme)
          != JobPresentation.Tone.neutral.color(for: scheme))
    }
  }

  /// The running icon sits directly above the bar it describes, so it takes
  /// the progress fill itself rather than a colour near it — two purples that
  /// are almost the same read as a mistake.
  @Test func theActiveToneIsTheProgressFillItself() {
    for scheme in [ColorScheme.light, .dark] {
      #expect(JobPresentation.Tone.active.color(for: scheme) == Brand.progressFill(for: scheme))
    }
  }
}
