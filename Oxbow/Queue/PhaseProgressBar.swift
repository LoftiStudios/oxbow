import SwiftUI
import OxbowKit

/// One step's progress as a segmented bar: a segment per phase, filled behind
/// you, partly filled where you are, empty ahead.
///
/// **Why not one bar.** A VOD download is four phases and the CLI reports a
/// percentage per phase, so a single `ProgressView` bound to that percentage
/// runs 0→100% four times over — which reads as three false finishes. A
/// continuous bar would fix the resets but hide the structure, and since the
/// phases are nothing like equal in length ("Downloading" dwarfs "Fetching
/// Video Info") a smooth bar that crawls and then leaps looks broken. Showing
/// the segments is what makes uneven progress read as expected instead.
struct PhaseProgressBar: View {
  let phases: StepPhases
  let progress: StepProgress

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let track: CGFloat = 5
  private static let gap: CGFloat = 3

  private var current: Int? { phases.index(matching: progress) }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: Self.gap) {
        ForEach(Array(phases.phases.enumerated()), id: \.offset) { index, _ in
          segment(at: index)
        }
      }
      .frame(height: Self.track)

      HStack(spacing: Self.gap) {
        ForEach(Array(phases.phases.enumerated()), id: \.offset) { index, phase in
          Text(phase.label)
            .font(.caption2)
            .foregroundStyle(index == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .lineLimit(1)
            // Labels are short but the queue's rows are not wide. Shrinking
            // beats truncating: "Commenter…" says less than small text does.
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fillOfCurrent)
    .accessibilityElement()
    .accessibilityLabel("Progress")
    .accessibilityValue(accessibilityValue)
  }

  private func segment(at index: Int) -> some View {
    Capsule()
      .fill(.quaternary)
      .overlay(alignment: .leading) {
        GeometryReader { proxy in
          Capsule()
            .fill(Color.accentColor)
            .frame(width: proxy.size.width * fill(at: index))
        }
      }
      .frame(maxWidth: .infinity)
  }

  /// A phase behind us is full, the one we are in is however far in we are,
  /// and everything ahead is empty. With no placeable phase nothing is filled
  /// — the caller draws an indeterminate bar in that case rather than this one.
  private func fill(at index: Int) -> Double {
    guard let current else { return 0 }
    if index < current { return 1 }
    if index > current { return 0 }
    return fillOfCurrent
  }

  /// The current phase's own percentage, or a full segment when it reports
  /// none. A phase like "Fetching Video Info" or "Writing Output File" never
  /// emits a percentage at all; leaving its segment empty would read as
  /// stalled, and the segments behind it already say we got past it.
  private var fillOfCurrent: Double {
    min(max(progress.fraction ?? 1, 0), 1)
  }

  private var accessibilityValue: String {
    guard let current, current < phases.phases.count else { return "Starting" }
    let phase = phases.phases[current].label
    guard let fraction = progress.fraction else {
      return "\(phase), step \(current + 1) of \(phases.phases.count)"
    }
    return "\(phase), \(Int(fraction * 100)) percent"
  }
}

#Preview("Video download, mid-verify") {
  VStack(alignment: .leading, spacing: 20) {
    ForEach(previewStages, id: \.0) { name, progress in
      VStack(alignment: .leading, spacing: 4) {
        Text(name).font(.caption).foregroundStyle(.secondary)
        PhaseProgressBar(
          phases: StepPhases.expected(for: previewVideoKind)!,
          progress: progress)
      }
    }
  }
  .padding()
  .frame(width: 420)
}

private let previewVideoKind = StepKind.downloadVideo(VideoRequest(
  videoID: "1", quality: "", destination: URL(filePath: "/tmp/a.mp4")))

/// The real sequence a VOD download walks through, as captured in
/// `videodownload-success.stdout`.
private let previewStages: [(String, StepProgress)] = [
  ("Fetching Video Info [1/4]", StepProgress(phase: "Fetching Video Info", index: 1, total: 4)),
  ("Downloading 40% [2/4]",
   StepProgress(phase: "Downloading", fraction: 0.4, index: 2, total: 4)),
  ("Verifying Parts 50% [3/4]",
   StepProgress(phase: "Verifying Parts", fraction: 0.5, index: 3, total: 4)),
  ("Finalizing Video 98% [4/4]",
   StepProgress(phase: "Finalizing Video", fraction: 0.98, index: 4, total: 4)),
]

#Preview("Chat render — counter vanishes on phase two") {
  let kind = StepKind.renderChat(RenderRequest(destination: URL(filePath: "/tmp/a.mp4")))
  return VStack(alignment: .leading, spacing: 20) {
    PhaseProgressBar(
      phases: StepPhases.expected(for: kind)!,
      progress: StepProgress(phase: "Fetching Images", index: 1, total: 2))
    PhaseProgressBar(
      phases: StepPhases.expected(for: kind)!,
      progress: StepProgress(phase: "Rendering Video", fraction: 0.62))
  }
  .padding()
  .frame(width: 420)
}
