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

  /// The delivered files' size on disk, measured off the main path in the same
  /// task as the metadata. Nil until measured, and nil when it cannot be.
  @State private var deliveredBytes: Int64?

  @Environment(\.colorScheme) private var colorScheme

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
    let job = job(for: target)
    VStack(spacing: 0) {
      Form {
          // **Identical to the window's**, from the same loader.
          // `video-record.md` §4.1's "one component", and `inspector.md` §11
          // rejects a compact variant outright: if this reads badly at 300pt
          // the fix belongs in `VideoCard`, not in a second card here.
          //
          // The card draws its own title, streamer and date line, which is why
          // none of those are repeated below it.
        Section {
          switch metadata {
          case .loading:
            VideoCard(.loading)
          case .loaded(let info):
            VideoCard(info: info)
          case .unavailable:
            VideoCard(.unavailable(title: job?.title ?? "Video"))
          }

        }

        if let job {
          facts(JobInfo(job: job))
        } else {
          // No job, but the card above still describes the video — which is
          // `video-record.md` §4.3's case: a watched archive you have not
          // downloaded has a card, a date and a duration, and one line saying
          // you do not have it.
          Section {
            Text("Not downloaded").foregroundStyle(.secondary)
          }
        }
      }
      // The same style Get Info uses, so the two read as one app rather than
      // two surfaces that happen to show the same facts.
      .formStyle(.grouped)

      if let job {
        Divider()
        // Shared with the window — see `SavedToFooter`. Pinned rather than
        // scrolled: "where did that go" should not require reaching the
        // bottom of a card.
        SavedToFooter(info: JobInfo(job: job))
      }
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
      deliveredBytes = nil
      guard let controller else { return }
      metadata = await VideoInfoLoad.resolve(
        identifier: VideoInfoLoad.identifier(for: target, jobs: controller.jobs),
        controller: controller, record: record,
        // **Record first here, live first in the window.** This pane is
        // glanced at while arrowing down a list; paying an `info` subprocess
        // per row made that cost a second each and spent bandwidth on
        // metadata already sitting in `videos.json`. See
        // `VideoInfoLoad.Freshness`.
        freshness: .remembered)
      deliveredBytes = Self.sizeOnDisk(of: job?.deliveredFiles ?? [])
    }
  }

  /// What the download was asked to do, and what it produced.
  ///
  /// **Every value here is `JobInfo`'s**, the same property `JobInfoWindow`'s
  /// own Download section reads, rendered by the same `JobStatusValue`. The
  /// two surfaces show a different *amount* — §4's table gives the window the
  /// step breakdown and keeps it out of here — but never a different *answer*.
  ///
  /// **`LabeledContent` in a grouped `Form`, not a hand-rolled row.** That is
  /// what gives a label its primary weight and a value its secondary one,
  /// which is the convention every Apple inspector-style list follows and the
  /// one Get Info already follows two feet away. An earlier version here drew
  /// the values in medium weight, which emphasised all of them and therefore
  /// none — and disagreed with the window about the same five facts.
  private func facts(_ info: JobInfo) -> some View {
    Section("Download") {
      LabeledContent("Status") { JobStatusValue(status: info.job.status) }
      LabeledContent("Outputs", value: info.outputs.joined(separator: ", "))
      if !info.quality.isEmpty {
        LabeledContent("Quality", value: info.quality)
      }
      LabeledContent("Trim", value: info.trim)
      // **Shown only when every delivered file could be measured** — the same
      // rule §5.3 applies to the multi-selection estimate, for the same
      // reason. A file on an unmounted volume cannot be sized, and a total
      // that quietly omitted it would read as a smaller download rather than
      // an unmeasured one.
      if let deliveredBytes {
        LabeledContent(
          "Filesize", value: deliveredBytes.formatted(.byteCount(style: .file)))
      }
    }
  }

  /// The delivered files' total size, or nil if any of them could not be read.
  ///
  /// Never a partial sum, and never zero standing in for "could not ask" — the
  /// distinction `VolumeSpace.nearestExisting` exists to preserve, applied to a
  /// smaller number. A download on a disconnected volume shows no size rather
  /// than a wrong one.
  private static func sizeOnDisk(of files: [URL]) -> Int64? {
    guard !files.isEmpty else { return nil }
    var total = Int64(0)
    for file in files {
      guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize
      else { return nil }
      total += Int64(size)
    }
    return total
  }

  @ViewBuilder
  private func multiple(_ many: MultiSelection) -> some View {
    Form {
      Section {
        // §5.1: Mail's shape. Above the text, because it is what identifies
        // the selection — the count merely sizes it.
        if !many.thumbnails.isEmpty {
          SelectionStack(thumbnails: many.thumbnails, store: imageStore)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text("\(many.count) downloads selected")
            .font(.headline)
          // Which channels, not how many of each. The names are what makes a
          // mis-selection obvious — "I meant only LeighXP" — and they are
          // display names because `VideoRecord.displayName` now keeps them.
          if !many.channels.isEmpty {
            Text(many.channels.joined(separator: ", "))
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      Section("Download") {
        LabeledContent("Status") { statusValue(many) }
        // **Shown only when every selected job could be priced** (§5.3). When
        // one could not, this row is absent rather than smaller — a total
        // that silently drops two of five looks complete and is not, and a
        // disk figure is exactly the kind people act on.
        //
        // "about", matching how the Add Channel sheet words its own estimate,
        // because this is a model of a download rather than a measurement of
        // one — unlike the single case's Filesize, which is measured.
        if let bytes = many.estimatedBytes {
          LabeledContent(
            "Filesize", value: "about \(bytes.formatted(.byteCount(style: .file)))")
        }
      }
    }
    .formStyle(.grouped)
  }

  /// One status row for a whole selection.
  ///
  /// **Uniform reads as a count of one thing** — "22 Finished" — which is what
  /// a person wants nine times in ten. Mixed spells out the parts instead, and
  /// takes the icon of the most serious status present: a selection that is
  /// mostly finished with two failures in it is a selection with a problem,
  /// and a green check over that would be the pane reassuring somebody about
  /// the wrong thing (§5.2).
  @ViewBuilder
  private func statusValue(_ many: MultiSelection) -> some View {
    let parts: [(JobStatus, Int)] = [
      (.failed, many.failed), (.cancelled, many.cancelled),
      (.running, many.running), (.queued, many.queued), (.done, many.done),
    ].filter { $0.1 > 0 }

    // Already ordered most-serious-first above, so the first present one is
    // the one to show.
    let lead = parts.first?.0 ?? .queued
    let icon = JobPresentation.icon(for: lead)

    HStack(spacing: QueueMetrics.iconSpacing) {
      Image(systemName: icon.name)
        .foregroundStyle(icon.tone.color(for: colorScheme))
        .accessibilityHidden(true)
      if parts.count == 1 {
        Text("\(many.count) \(JobPresentation.accessibilityStatus(of: lead).capitalized)")
      } else {
        Text(parts
          .map { "\($0.1) \(JobPresentation.accessibilityStatus(of: $0.0))" }
          .joined(separator: " · "))
      }
    }
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
