import SwiftUI
import Testing
@testable import Oxbow

@Suite("Queue style")
struct QueueStyleTests {

  /// Pending and neutral must render distinct colors, not just distinct enum cases.
  @Test func pendingAndInertAreDifferentGreys() {
    for scheme in [ColorScheme.light, .dark] {
      #expect(
        JobPresentation.Tone.pending.color(for: scheme)
          != JobPresentation.Tone.neutral.color(for: scheme))
    }
  }

  /// The running icon uses the bar's exact fill color.
  @Test func theActiveToneIsTheProgressFillItself() {
    for scheme in [ColorScheme.light, .dark] {
      #expect(JobPresentation.Tone.active.color(for: scheme) == Brand.progressFill(for: scheme))
    }
  }
}
