import Foundation

/// The named phases a step passes through, so progress can be drawn as one
/// segmented bar rather than as a bar that fills and resets several times.
///
/// **Why names and not the counter.** The CLI's `[i/n]` counter is not
/// reliably present, and the places it goes missing are the worst ones:
/// `ChatRenderer` announces `Fetching Images [1/2]` and then drops the counter
/// for `Rendering Video`, which is the phase that takes all the time, and
/// `ChatDownloader` emits no counter on any phase at all. A bar driven off the
/// counter alone would stall on segment one of a render and never move.
///
/// The names, by contrast, are stable and knowable: these lists come from
/// upstream's own format strings, not from one captured run. The counter is
/// kept as a fallback for when a name is not recognised.
///
/// This is a second dependency on the CLI's text, alongside
/// `StatusLineParser` — which is why it lives next to it, and why
/// `StepPhasesTests` replays the captured fixtures through it. That test fails
/// the day upstream renames a phase, which is exactly when a segmented bar
/// would otherwise begin silently stalling.
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
      // `ChatDownloader` only emits "Downloading Embed Images" when it was
      // asked to embed them. A fixed fourth segment would leave a gap that
      // never fills on every chat download that does not.
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

    case .composite:
      // FFmpeg emits no phase names — `-progress` reports a real fraction
      // instead, so there is one segment and it fills smoothly. The label
      // matches the phase `FFmpegProgressParser` stamps on every update.
      StepPhases(phases: [Phase("Compositing", "Combine")])
    }
  }

  /// Where in this sequence a status line puts us, or nil if it cannot be
  /// placed at all.
  ///
  /// Name first, counter second. The counter is only trusted when it agrees
  /// about how many phases there are: `TsMerger` emits its own `[1/2]`
  /// sequence containing a "Verifying Parts" that also appears in the
  /// four-phase video flow, and a total that does not match means we are not
  /// looking at the sequence we think we are.
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

  /// How far through the whole step we are: completed phases plus however far
  /// into the current one we have got.
  ///
  /// Nil rather than zero when the phase cannot be placed — a bar that reads
  /// "0%" claims knowledge we do not have, where an indeterminate one is
  /// honest about it.
  ///
  /// Phases are treated as equal shares, which they are not: `Downloading` is
  /// far longer than `Fetching Video Info`. That makes the bar move unevenly,
  /// but never backwards, and the segments are visible precisely so uneven
  /// progress reads as expected rather than broken.
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
