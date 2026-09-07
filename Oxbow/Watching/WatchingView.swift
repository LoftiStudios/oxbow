import AppKit
import SwiftUI
import OxbowKit

/// The Watching list itself: one section per channel, `ArchiveRow`s under the
/// quiet ones, and a failure message standing in for rows under the broken
/// ones.
///
/// **A failed channel must never look like a channel with nothing new.**
/// `WatchingModel.Section.failure` exists precisely so those two states cannot
/// be confused — a quiet channel is nil failure and an empty list; a broken
/// one carries a message (design §7: a parse failure degrades to a visible
/// error, never to something indistinguishable from "no new videos"). This
/// view is where that distinction has to actually show up, so a failed
/// section renders its message in the space rows would otherwise occupy
/// rather than falling through to the same "nothing here" the quiet case
/// gets.
///
/// **A quiet channel's header still appears, with nothing beneath it.** A
/// list of several watched channels, most of them quiet, is the ordinary
/// case, and a "no new videos" row under every one of them would be the loud
/// thing on a screen that is trying to be quiet.
///
/// **A demoted channel must not look like a quiet one either — the same
/// requirement applied to `AutoDownloadPolicy`'s decision instead of a fetch
/// failure.** A watch that hit the free-space floor or lost its destination
/// keeps polling and keeps listing what it finds; only its automatic half
/// paused. `DemotionRow` says so beside those findings, and `ChannelCard`
/// swaps its bolt for a paused one, so both the list and the card answer
/// "why didn't this just download?" without anyone having to guess that
/// nothing being queued and nothing being found are different problems.
struct WatchingView: View {
  let sections: [WatchingModel.Section]
  /// Whether `WatchPoller` is mid-sweep right now.
  ///
  /// Sweeps are sequential, one request per channel with a 15-second
  /// timeout (`WatchPoller.live`), so with several watches the gap between
  /// launch and the first sweep landing can run to minutes. Without this,
  /// `sections.isEmpty` cannot tell that window apart from having nothing
  /// watched at all, and would spend it telling someone with several watches
  /// that they have none.
  let isSweeping: Bool
  /// Which watches the last sweep demoted to notify-only, keyed by login —
  /// `WatchPoller.demotions`, passed straight through the same way
  /// `isSweeping` is: this view has no store of its own to compute it from,
  /// and `WatchingModel.Section` (built from `watches.json` and a sweep's
  /// findings) has nothing to say about *why* automatic downloading paused,
  /// only that a channel is set to want it.
  let demotions: [String: AutoDownloadPolicy.Reason]

  /// Where `ChannelAvatar` reads cached bytes from. Optional for the same
  /// reason `watching` and `poller` are on `QueueView`: `OxbowApp` builds it
  /// only once a support directory resolves, and never under
  /// `xcodebuild test`. Nil renders the placeholder.
  var imageStore: ImageStore? = nil

  let onAdd: (ChannelArchive, WatchingModel.Section) -> Void

  /// The row's secondary action — see `ArchiveRow.onAddWithOptions`.
  var onAddWithOptions: (ChannelArchive, WatchingModel.Section) -> Void = { _, _ in }
  let onIgnore: (ChannelArchive, WatchingModel.Section) -> Void
  /// Opens the Add Channel window in editing mode, seeded from this
  /// section's own watch — `docs/design/channel-watching.md` §3.2's "offer
  /// an Edit". Reached from the same context menu as Stop Watching, since
  /// both are things a section header offers about its own channel and
  /// nothing else on screen does.
  let onEdit: (WatchingModel.Section) -> Void
  /// Stops watching the channel a section's header menu named. No
  /// confirmation on this side either — see `ChannelCard`'s own doc
  /// comment for why none is offered.
  let onStopWatching: (WatchingModel.Section) -> Void
  /// Set when a Stop Watching refused rather than removing anything —
  /// `WatchingModel.stopWatchingFailure`'s own counterpart on this side.
  ///
  /// The whole point of refusing rather than silently overwriting the watch
  /// list (see that property's own doc comment) is to tell the user why; a
  /// refusal nothing displays is indistinguishable from Stop Watching simply
  /// not working. `AddChannelModel.addFailure` gets the identical visible
  /// treatment in its own window, for the identical reason.
  let stopWatchingFailure: String?
  /// Set when Ignore or Add could not persist because the watch list could
  /// not be read — `WatchingModel.markSeenFailure`'s own counterpart on this
  /// side, for the identical reason `stopWatchingFailure` above gets one:
  /// `dismissed` already hides the row the moment either button is pressed,
  /// so without this a read failure made the row vanish with nothing on
  /// screen to say why.
  let markSeenFailure: String?

  /// Why the last Add did not reach the queue — `WatchingModel
  /// .submissionFailure`'s counterpart. Its own banner rather than folded
  /// into `markSeenFailure`: that one means "the row is hidden but the file
  /// did not record it", this one means the opposite — nothing was hidden
  /// and nothing was queued.
  var submissionFailure: String? = nil

  var body: some View {
    VStack(spacing: 0) {
      if let stopWatchingFailure {
        QueueBanner(title: "Couldn't stop watching", message: stopWatchingFailure)
        Divider()
      }
      if let markSeenFailure {
        QueueBanner(title: "Couldn't save that", message: markSeenFailure)
        Divider()
      }
      if let submissionFailure {
        QueueBanner(title: "Couldn't queue that", message: submissionFailure)
        Divider()
      }
      content
    }
  }

  @ViewBuilder
  private var content: some View {
    if sections.isEmpty {
      if isSweeping {
        // Distinct from the genuinely-empty case below, and deliberately not
        // claiming anything about what it will find: a sweep that turns up
        // nothing lands right back here with `isSweeping` false, which is
        // exactly the "No channels watched yet" state — still honest, since
        // nothing here can create a watch from the UI yet either.
        ContentUnavailableView {
          Label("Checking your channels", systemImage: "eye")
        } description: {
          Text("Looking for new videos. This can take a while with several channels.")
        }
      } else {
        // Not "loading" — there is a real difference between nothing to check
        // in the first place and a sweep still in flight, and until the next
        // plan adds a way to watch a channel from here, this *is* the nothing-
        // to-check case for everyone who opens it.
        ContentUnavailableView {
          Label("No channels watched yet", systemImage: "eye")
        }
      }
    } else {
      List {
        ForEach(sections) { section in
          Section {
            if let failure = section.failure {
              FailureRow(message: failure)
            } else {
              // Demotion never withholds a finding — `AutoDownloadPolicy
              // .decide` only withholds automatic *submission* — so a
              // demoted channel's rows below are the exact `ArchiveRow`s an
              // ordinary, non-automatic channel would show. This row only
              // explains why they were not queued unattended; it never
              // replaces them, which is what tells a demoted channel apart
              // from a failed one (`FailureRow` above stands in for its rows,
              // this stands alongside them).
              if let reason = demotions[section.login] {
                DemotionRow(reason: reason)
              }
              ForEach(section.rows) { row in
                ArchiveRow(
                  row: row,
                  store: imageStore,
                  onAdd: { onAdd(row.archive, section) },
                  onIgnore: { onIgnore(row.archive, section) },
                  onAddWithOptions: { onAddWithOptions(row.archive, section) },
                  onReveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) })
              }
            }
          } header: {
            ChannelCard(
              section: section,
              imageStore: imageStore,
              demotionReason: demotions[section.login],
              onEdit: { onEdit(section) },
              onStopWatching: { onStopWatching(section) })
          }
        }
      }
      // Matches `QueueView`'s list: rows here vary in height too — a failed
      // section's message wraps to however many lines it needs — and banding
      // is what keeps one channel's section visually separate from the next.
      .alternatingRowBackgrounds()
    }
  }
}

/// A failed channel's stand-in for its rows.
///
/// Deliberately not `QueueBanner`: that one sits above a whole window and
/// argues for itself with a headline. This sits inside one `Section` among
/// several, so it has to read at a glance as "this channel, not the others"
/// without shouting over quiet ones sitting right next to it in the same
/// list.
private struct FailureRow: View {
  let message: String

  var body: some View {
    Label {
      Text(message)
        .foregroundStyle(.secondary)
        // The messages here are `Error.localizedDescription`, not something
        // this view controls the length of, so they wrap rather than clip.
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}

/// A demoted channel's explanation, shown alongside its ordinary findings —
/// never instead of them (see the call site's own comment).
///
/// **A different icon and message from `FailureRow`, deliberately — the same
/// distinction §7 of `docs/design/channel-watching.md` draws for a failed
/// sweep, applied here a second time.** A triangle there means the sweep
/// itself broke and there is nothing underneath it to look at, which is
/// exactly the shape a "no new videos" row must never be confused with. A
/// demotion is a different situation again: the sweep succeeded, its
/// findings are listed right below, and only the unattended half paused. The
/// paused icon reused here for that reason also appears on the card's own
/// header (`ChannelCard.demotionReason`) — one glance at either place
/// answers the same question the same way.
private struct DemotionRow: View {
  let reason: AutoDownloadPolicy.Reason

  var body: some View {
    Label {
      Text(reason.sentence)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "pause.circle.fill")
        .foregroundStyle(.orange)
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}

#Preview("Two channels, findings") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        rows: [WatchingViewPreviewData.normal, WatchingViewPreviewData.longTitle].map { WatchingModel.Row(archive: $0, state: .available) },
        failure: nil, settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
        downloadsAutomatically: false),
      WatchingModel.Section(
        login: "quietchannel", displayName: "A Quiet Channel",
        rows: [], failure: nil,
        settingsSummary: "Video · Up to 720p · Archive", downloadsAutomatically: false),
    ],
    isSweeping: false, demotions: [:],
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil, markSeenFailure: nil)
  .frame(width: 480, height: 420)
}

// New: a refused Stop Watching has to say why, the same visible treatment
// `AddChannelModel.addFailure` gets in its own window — see
// `WatchingModel.stopWatchingFailure`'s own doc comment.
#Preview("Stop Watching failed") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        rows: [WatchingViewPreviewData.normal].map { WatchingModel.Row(archive: $0, state: .available) }, failure: nil,
        settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
        downloadsAutomatically: false),
    ],
    isSweeping: false, demotions: [:],
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: "Oxbow could not read the watch list, so LeighXP was not stopped.",
    markSeenFailure: nil)
  .frame(width: 480, height: 420)
}

// New: Ignore and Add both hide their row through `dismissed` before ever
// touching the store, so a read failure used to make the row vanish with
// nothing on screen to say why — `WatchingModel.markSeenFailure`'s own doc
// comment.
#Preview("Ignore or Add failed") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        rows: [WatchingViewPreviewData.normal].map { WatchingModel.Row(archive: $0, state: .available) }, failure: nil,
        settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
        downloadsAutomatically: false),
    ],
    isSweeping: false, demotions: [:],
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil,
    markSeenFailure: "Oxbow could not read the watch list: the file could not be read.")
  .frame(width: 480, height: 420)
}

#Preview("One channel failed") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        rows: [WatchingViewPreviewData.normal].map { WatchingModel.Row(archive: $0, state: .available) }, failure: nil,
        settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
        downloadsAutomatically: false),
      WatchingModel.Section(
        login: "brokenchannel", displayName: "A Broken Channel",
        rows: [],
        failure: "The response did not include the expected video list.",
        settingsSummary: "Video · Up to 1080p · Downloads", downloadsAutomatically: false),
    ],
    isSweeping: false, demotions: [:],
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil, markSeenFailure: nil)
  .frame(width: 480, height: 420)
}

// New for Task 2: a watched channel that has never turned up anything —
// either the last sweep found nothing, or it hasn't been polled yet — must
// still show its own section with its settings, not a bare header or
// nothing at all (`docs/design/channel-watching.md` §3.2's whole premise).
#Preview("Channel with no findings") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "quietchannel", displayName: "A Quiet Channel",
        rows: [], failure: nil,
        settingsSummary: "Video + chat · Best available · Small chat · Downloads",
        downloadsAutomatically: false),
    ],
    isSweeping: false, demotions: [:],
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil, markSeenFailure: nil)
  .frame(width: 480, height: 420)
}

// Automatic downloading is off by default and consequential (§2, §11.1) — a
// channel that has it on has to be visibly different from one that does not.
#Preview("One channel downloads automatically") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        rows: [WatchingViewPreviewData.normal].map { WatchingModel.Row(archive: $0, state: .available) }, failure: nil,
        settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
        downloadsAutomatically: true),
      WatchingModel.Section(
        login: "quietchannel", displayName: "A Quiet Channel",
        rows: [], failure: nil,
        settingsSummary: "Video · Up to 720p · Archive", downloadsAutomatically: false),
    ],
    isSweeping: false, demotions: [:],
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil, markSeenFailure: nil)
  .frame(width: 480, height: 420)
}

// New for Task 5: a watch demoted for the disk-floor reason still shows its
// findings, unlike a failed sweep — `DemotionRow` sits above them rather than
// replacing them, and the header's bolt turns orange rather than vanishing.
#Preview("Channel demoted, below floor") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        rows: [WatchingViewPreviewData.normal, WatchingViewPreviewData.longTitle].map { WatchingModel.Row(archive: $0, state: .available) },
        failure: nil, settingsSummary: "Video + chat · Best available · Medium chat · Archive",
        downloadsAutomatically: true),
      WatchingModel.Section(
        login: "quietchannel", displayName: "A Quiet Channel",
        rows: [], failure: nil,
        settingsSummary: "Video · Up to 720p · Downloads", downloadsAutomatically: false),
    ],
    isSweeping: false,
    demotions: ["leighxp": .belowFloor(needed: 2_600_000_000, available: 12_000_000_000, floor: 49_000_000_000)],
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil, markSeenFailure: nil)
  .frame(width: 480, height: 420)
}

// New for Task 5: the other of the two demotion causes — an unreachable
// destination takes precedence over the floor when both apply
// (`AutoDownloadPolicy.decide`), so this is its own reason, its own sentence.
#Preview("Channel demoted, destination unreachable") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        rows: [WatchingViewPreviewData.normal].map { WatchingModel.Row(archive: $0, state: .available) }, failure: nil,
        settingsSummary: "Video + chat · Best available · Medium chat · Archive",
        downloadsAutomatically: true),
    ],
    isSweeping: false,
    demotions: ["leighxp": .destinationUnreachable("/Volumes/Archive")],
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil, markSeenFailure: nil)
  .frame(width: 480, height: 420)
}

#Preview("No channels watched") {
  WatchingView(
    sections: [], isSweeping: false, demotions: [:],
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil, markSeenFailure: nil)
    .frame(width: 480, height: 420)
}

#Preview("Checking, first sweep") {
  // The window between launch and the first sweep landing: `sections` is
  // still empty, but this must not read as "no channels watched" — see
  // `isSweeping`'s doc above.
  WatchingView(
    sections: [], isSweeping: true, demotions: [:],
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onEdit: { _ in }, onStopWatching: { _ in },
    stopWatchingFailure: nil, markSeenFailure: nil)
    .frame(width: 480, height: 420)
}

/// Fixtures for the previews above.
///
/// Not `ArchiveRowPreviewData`: those pin `publishedAt` against a fixed `now`
/// that `ArchiveRow`'s own previews pass back in, so the age reads sensibly.
/// This view never threads a `now` down to the rows it builds — a real
/// `WatchingView` shouldn't either, since the age is supposed to track
/// whatever "today" actually is — so these fixtures anchor `publishedAt` to
/// the real clock instead, or the fixed fixture's age would drift by a day
/// for every day this file goes unread.
private enum WatchingViewPreviewData {
  static let normal = ChannelArchive(
    id: "1", title: "Indie horror night",
    duration: .seconds(3 * 3600 + 24 * 60),
    publishedAt: Date().addingTimeInterval(-12 * 86400),
    status: .recorded, thumbnailURL: nil)

  static let longTitle = ChannelArchive(
    id: "2",
    title: "LeighXP - 2026-08-12 - indie horror + something else later?? "
      + "also chatting about the new patch notes and taking questions",
    duration: .seconds(5 * 3600),
    publishedAt: Date(),
    status: .recorded, thumbnailURL: nil)
}
