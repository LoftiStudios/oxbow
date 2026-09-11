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
/// **The card is the window's, not a copy of it.** Both render `VideoCard`
/// from the same `VideoInfoLoad`, which is §4's contract: the card is
/// identical on both surfaces and the sections beneath are each pane's own.
/// The full step breakdown and the delivered-files list stay in the window —
/// that is what keeps it worth opening rather than a wider inspector. §11
/// rejects a compact card variant outright: if this reads badly at 300pt, the
/// fix belongs in `VideoCard`.
struct InspectorPane: View {
  let subject: InspectorSubject
  let controller: QueueController?
  /// Where an expired video's metadata comes from once Twitch has stopped
  /// answering. Optional for the same reason it is on `JobInfoWindow`:
  /// `OxbowApp` builds it only once a support directory resolves.
  var record: VideoRecordStore? = nil
  /// Where the selection stack reads cached frames from. The same store the
  /// watching surfaces use — this adds no fetching of its own.
  var imageStore: ImageStore? = nil

  /// The shared loader's answer for whatever is selected.
  ///
  /// **The same `VideoInfoLoad` the window uses**, not a second route to the
  /// same fact — §4: the card must not fork, and a card is only as shared as
  /// the thing feeding it.
  @State private var metadata: VideoInfoLoad = .loading

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
        // **Identical to the window's**, from the same loader.
        // `video-record.md` §4.1's "one component", and `inspector.md` §11
        // rejects a compact variant outright: if this reads badly at 300pt
        // the fix belongs in `VideoCard`, not in a second card here.
        switch metadata {
        case .loading:
          VideoCard(.loading)
        case .loaded(let info):
          VideoCard(info: info)
        case .unavailable:
          VideoCard(.unavailable(title: job(for: target)?.title ?? "Video"))
        }

        if let job = job(for: target) {
          // **No job title here.** The card above already names the video,
          // and a job's title is that name with the channel and date prefixed
          // — printed under the card it reads as the same sentence twice.
          // §4's table lists the card, the facts, a one-line status and Show
          // in Finder; the title was never one of them.
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
          // No job, but the card above still describes the video — which is
          // `video-record.md` §4.3's case: a watched archive you have not
          // downloaded has a card, a date and a duration, and one line saying
          // you do not have it.
          Text("Not downloaded")
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    // Keyed on the identifier, matching `JobInfoWindow`'s own `.task(id:)`,
    // so moving between two rows for the same video does not refetch.
    .task(id: VideoInfoLoad.identifier(for: target, jobs: controller?.jobs ?? [])) {
      // **Cleared first, every time.** `metadata` survives a change of
      // subject, so without this the pane keeps drawing the *previous*
      // video's card — its artwork, its title, its streamer — beneath a row
      // that is not about it, until the new fetch lands. A placeholder is a
      // far smaller lie than another video, and this pane exists to be
      // glanced at rather than read carefully, which is exactly the habit a
      // wrong card would poison.
      metadata = .loading
      guard let controller else { return }
      metadata = await VideoInfoLoad.resolve(
        identifier: VideoInfoLoad.identifier(for: target, jobs: controller.jobs),
        controller: controller, record: record)
    }
  }

  @ViewBuilder
  private func multiple(_ many: MultiSelection) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      // §5.1: Mail's shape. Above the text, because it is what identifies the
      // selection — the count merely sizes it.
      if !many.thumbnails.isEmpty {
        SelectionStack(thumbnails: many.thumbnails, store: imageStore)
      }
      Text("\(many.count) downloads selected")
        .font(.headline)
      Text(statusSummary(many))
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      // **Shown only when every selected job could be priced** (§5.3). When
      // one could not, this line is absent rather than smaller — a total that
      // silently drops two of five looks complete and is not, and a disk
      // figure is exactly the kind people act on.
      //
      // "about", matching how the Add Channel sheet words its own estimate,
      // because this is a model of a download rather than a measurement of
      // one.
      if let bytes = many.estimatedBytes {
        Text("about \(bytes.formatted(.byteCount(style: .file)))")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
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

#Preview("Several selected, priced") {
  InspectorPane(
    subject: .many(MultiSelection(
      count: 5, queued: 3, failed: 2, estimatedBytes: 12_400_000_000)),
    controller: nil)
    .frame(width: 300, height: 420)
}

// §5.3's other half: one of these could not be priced, so the size line is
// absent rather than quoting a total that silently dropped it.
#Preview("Several selected, unpriceable") {
  InspectorPane(
    subject: .many(MultiSelection(count: 5, queued: 3, failed: 2)),
    controller: nil)
    .frame(width: 300, height: 420)
}

// `video-record.md` §4.3: a video nothing has downloaded still has a card.
// Renders `.unavailable` here because a preview has no controller to fetch
// with, which is also what an expired video looks like.
#Preview("One selected, not downloaded") {
  InspectorPane(subject: .one(.video("2844787557")), controller: nil)
    .frame(width: 300, height: 420)
}
