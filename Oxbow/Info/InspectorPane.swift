import AppKit
import SwiftUI
import OxbowKit

/// The trailing inspector: what is selected, right now.
///
/// `docs/design/inspector.md`. **Beside the Get Info window, not instead of
/// it** (§2). This answers "what am I looking at"; the window answers "keep
/// this in front of me". Finder ships both — ⌘I opens a window per item, ⇧⌘P
/// shows a pane that follows the selection — and they are not felt as
/// competing because they are not answering the same question.
///
/// **No `VideoCard` yet.** Slice B shares the window's, which means first
/// extracting the metadata loading out of `JobInfoWindow`. Until then this
/// shows what it can name without a fetch, rather than growing a second,
/// lesser card that would have to be deleted again — §11 rejects a compact
/// variant outright.
struct InspectorPane: View {
  let subject: InspectorSubject
  let controller: QueueController?

  var body: some View {
    Group {
      switch subject {
      case .nothing:
        empty
      case .one(let target):
        single(target)
      case .many(let many):
        multiple(many)
      }
    }
    // §8: the window's floor is 660pt and this lands comfortable use near
    // 1000. Collapsible, and its width is remembered.
    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
  }

  /// §6: a placeholder, deliberately **not** the channel card or queue totals.
  /// Both are tempting and both would make the pane show a different *kind* of
  /// thing depending on state, and a pane whose subject changes category when
  /// you deselect is one you cannot stop looking at on purpose.
  private var empty: some View {
    ContentUnavailableView {
      Label("Nothing selected", systemImage: "sidebar.right")
    } description: {
      Text("Select a download or an archive to see its details.")
    }
  }

  @ViewBuilder
  private func single(_ target: InfoTarget) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if let job = job(for: target) {
          Text(job.title)
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)

          LabeledContent("Status", value: statusText(job.status))

          // The one ambient *action* worth carrying (§4). "Where did that go"
          // is asked far more often than "which of the four steps failed",
          // and the second stays the window's job.
          //
          // `Job.deliveredFiles` rather than a second accessor of our own —
          // it is what `JobInfoWindow` already asks, and it is only the files
          // that actually landed, not the workspace copies.
          if !job.deliveredFiles.isEmpty {
            Button("Show in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting(job.deliveredFiles)
            }
          }
        } else {
          // A target that names a video the queue has never carried — an
          // archive selected in the Watching pane, once slice C wires that up.
          // Slice B's card is what will make this case say something useful;
          // saying little is better than saying something wrong.
          Text("Not in the queue")
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private func multiple(_ many: MultiSelection) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("\(many.count) downloads selected")
        .font(.headline)
      Text(statusSummary(many))
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The queue's job for this target, when it has one.
  ///
  /// Matches a `.video` target on `mediaIdentifier`, which is the same join
  /// `video-record.md` §3.1 calls "the key to everything" — an archive id and
  /// a job's video id are the same string.
  private func job(for target: InfoTarget) -> Job? {
    guard let controller else { return nil }
    switch target {
    case .job(let id):
      return controller.jobs.first { $0.id == id }
    case .video(let media):
      return controller.jobs.first { $0.mediaIdentifier == media }
    }
  }

  private func statusText(_ status: JobStatus) -> String {
    switch status {
    case .queued: return "Queued"
    case .running: return "Downloading"
    case .done: return "Done"
    case .failed: return "Failed"
    case .cancelled: return "Cancelled"
    }
  }

  /// **Only non-zero parts appear.** A row of five counts, four of them zero,
  /// is the loud thing on a quiet screen that `WatchingView`'s own doc comment
  /// already argues against for a "no new videos" row under every channel.
  ///
  /// The failure count is the line that earns this whole feature (§5.2):
  /// selecting a run of rows and reading "4 failed" is how a systematic
  /// problem gets noticed without opening four windows.
  private func statusSummary(_ many: MultiSelection) -> String {
    var parts: [String] = []
    if many.queued > 0 { parts.append("\(many.queued) queued") }
    if many.running > 0 { parts.append("\(many.running) downloading") }
    if many.done > 0 { parts.append("\(many.done) done") }
    if many.failed > 0 { parts.append("\(many.failed) failed") }
    if many.cancelled > 0 { parts.append("\(many.cancelled) cancelled") }
    return parts.joined(separator: " · ")
  }
}

#Preview("Nothing selected") {
  InspectorPane(subject: .nothing, controller: nil)
    .frame(width: 300, height: 420)
}

#Preview("Several selected") {
  InspectorPane(
    subject: .many(MultiSelection(count: 5, queued: 3, failed: 2)),
    controller: nil)
    .frame(width: 300, height: 420)
}

// The case the pane cannot yet say much about, kept visible so slice B's
// improvement is measurable against it rather than asserted.
#Preview("One selected, not in the queue") {
  InspectorPane(subject: .one(.video("2844787557")), controller: nil)
    .frame(width: 300, height: 420)
}
