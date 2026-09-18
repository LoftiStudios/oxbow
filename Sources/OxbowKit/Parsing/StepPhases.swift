import Foundation

/// Named CLI phases for segmented progress. Counters disappear during rendering and are absent
/// from chat downloads, so match upstream phase names first and use counters only as fallback.
/// Fixture tests detect renamed phases.
public struct StepPhases: Sendable, Equatable {

  public struct Phase: Sendable, Equatable {
    /// Matched against `StepProgress.phase`, which the parser leaves verbatim.
    public let cliName: String
    /// Ours, short enough to sit under a tick on the bar.
    public let label: String

    public init(_ cliName: String, _ label: String) {
      self.cliName = cliName
      self.label = label
    }
  }

  public let phases: [Phase]

  public init(phases: [Phase]) {
    self.phases = phases
  }

  /// What this step will go through, or nil if we do not know.
  ///
  /// Sourced from upstream: `VideoDownloader.cs`, `ClipDownloader.cs`,
  /// `ChatDownloader.cs` and `ChatRenderer.cs`.
  public static func expected(for kind: StepKind) -> StepPhases? {
    switch kind {
    case .downloadVideo:
      StepPhases(phases: [
        Phase("Fetching Video Info", "Info"),
        Phase("Downloading", "Download"),
        Phase("Verifying Parts", "Verify"),
        Phase("Finalizing Video", "Finalize"),
      ])

    case .downloadClip:
      StepPhases(phases: [
        Phase("Fetching Clip Info", "Info"),
        Phase("Downloading Clip", "Download"),
      ])

    case .downloadChat(let request):
      // Add the embed-images segment only when requested; otherwise it never runs.
      StepPhases(phases: [
        Phase("Downloading", "Download"),
        request.isEmbeddingImages ? Phase("Downloading Embed Images", "Images") : nil,
        Phase("Backfilling Commenter Info", "Commenters"),
        Phase("Writing Output File", "Write"),
      ].compactMap { $0 })

    case .renderChat:
      StepPhases(phases: [
        Phase("Fetching Images", "Images"),
        Phase("Rendering Video", "Render"),
      ])

    case .composite, .assemble:
      // FFmpeg reports a continuous fraction without phase names, so use one segment matching
      // the progress parser's label.
      StepPhases(phases: [Phase("Compositing", "Combine")])
    }
  }

  /// Matches by name, then by counter only if its total matches this sequence. Nested helper
  /// operations may report their own counters.
  public func index(matching progress: StepProgress) -> Int? {
    if let phase = progress.phase,
       let match = phases.firstIndex(where: { $0.cliName.caseInsensitiveCompare(phase) == .orderedSame })
    {
      return match
    }

    guard let index = progress.index, let total = progress.total, total == phases.count else {
      return nil
    }
    // The CLI counts from one.
    return min(max(index - 1, 0), phases.count - 1)
  }

  /// Completed phases plus the current phase's fraction, weighted equally. Nil means unknown
  /// phase. Unequal phase durations make this an approximate progress measure.
  public func overallFraction(for progress: StepProgress) -> Double? {
    guard !phases.isEmpty, let index = index(matching: progress) else { return nil }
    let share = 1.0 / Double(phases.count)
    let within = (progress.fraction ?? 0).clamped(to: 0...1)
    return (Double(index) + within) * share
  }
}

extension Comparable {
  fileprivate func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
