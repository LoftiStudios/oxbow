import SwiftUI
import OxbowKit

/// The Watching list itself: one section per channel, `FindingRow`s under the
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
  let onAdd: (ChannelArchive, WatchingModel.Section) -> Void
  let onIgnore: (ChannelArchive, WatchingModel.Section) -> Void
  /// Stops watching the channel a section's header menu named. No
  /// confirmation on this side either — see `SectionHeader`'s own doc
  /// comment for why none is offered.
  let onStopWatching: (WatchingModel.Section) -> Void

  var body: some View {
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
              ForEach(section.archives, id: \.id) { archive in
                FindingRow(
                  archive: archive,
                  channelName: section.displayName,
                  onAdd: { onAdd(archive, section) },
                  onIgnore: { onIgnore(archive, section) })
              }
            }
          } header: {
            SectionHeader(section: section, onStopWatching: { onStopWatching(section) })
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

/// A section's header: the channel name, what it is frozen to download at
/// (§3.2), a mark for automatic downloading when it is on, and — the only
/// place this is offered — Stop Watching.
///
/// **No confirmation dialog on Stop Watching.** Unlike removing a queued
/// download, this destroys nothing: it edits `watches.json` alone, and
/// every file a past download produced is untouched. A confirmation here
/// would be warning about a loss that does not happen, so the wording
/// carries that instead of a dialog — both the button's own label and its
/// tooltip say plainly that downloaded files stay put.
private struct SectionHeader: View {
  let section: WatchingModel.Section
  let onStopWatching: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(section.displayName)
      // Only shown when it is actually on: off is the default and the
      // ordinary case, and marking every quiet channel "Manual" would be
      // the loud thing `WatchingView`'s own doc comment already argues
      // against for a "no new videos" row under every quiet section.
      if section.downloadsAutomatically {
        Label("Downloads automatically", systemImage: "bolt.fill")
          .labelStyle(.iconOnly)
          .foregroundStyle(.blue)
          .help("Downloads automatically: new archives are queued without waiting for Add.")
      }
      Spacer(minLength: 0)
      if !section.settingsSummary.isEmpty {
        Text(section.settingsSummary)
          .foregroundStyle(.secondary)
      }
    }
    .textCase(nil)
    .contextMenu {
      Button {
        onStopWatching()
      } label: {
        Label("Stop Watching", systemImage: "eye.slash")
      }
      .help("""
        Stops watching \(section.displayName). Files already downloaded are \
        not deleted.
        """)
    }
  }
}

#Preview("Two channels, findings") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        archives: [WatchingViewPreviewData.normal, WatchingViewPreviewData.longTitle],
        failure: nil, settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
        downloadsAutomatically: false),
      WatchingModel.Section(
        login: "quietchannel", displayName: "A Quiet Channel",
        archives: [], failure: nil,
        settingsSummary: "Video · Up to 720p · Archive", downloadsAutomatically: false),
    ],
    isSweeping: false,
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onStopWatching: { _ in })
  .frame(width: 480, height: 420)
}

#Preview("One channel failed") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        archives: [WatchingViewPreviewData.normal], failure: nil,
        settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
        downloadsAutomatically: false),
      WatchingModel.Section(
        login: "brokenchannel", displayName: "A Broken Channel",
        archives: [],
        failure: "The response did not include the expected video list.",
        settingsSummary: "Video · Up to 1080p · Downloads", downloadsAutomatically: false),
    ],
    isSweeping: false,
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onStopWatching: { _ in })
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
        archives: [], failure: nil,
        settingsSummary: "Video + chat · Best available · Small chat · Downloads",
        downloadsAutomatically: false),
    ],
    isSweeping: false,
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onStopWatching: { _ in })
  .frame(width: 480, height: 420)
}

// Automatic downloading is off by default and consequential (§2, §11.1) — a
// channel that has it on has to be visibly different from one that does not.
#Preview("One channel downloads automatically") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        archives: [WatchingViewPreviewData.normal], failure: nil,
        settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
        downloadsAutomatically: true),
      WatchingModel.Section(
        login: "quietchannel", displayName: "A Quiet Channel",
        archives: [], failure: nil,
        settingsSummary: "Video · Up to 720p · Archive", downloadsAutomatically: false),
    ],
    isSweeping: false,
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onStopWatching: { _ in })
  .frame(width: 480, height: 420)
}

#Preview("No channels watched") {
  WatchingView(
    sections: [], isSweeping: false,
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onStopWatching: { _ in })
    .frame(width: 480, height: 420)
}

#Preview("Checking, first sweep") {
  // The window between launch and the first sweep landing: `sections` is
  // still empty, but this must not read as "no channels watched" — see
  // `isSweeping`'s doc above.
  WatchingView(
    sections: [], isSweeping: true,
    onAdd: { _, _ in }, onIgnore: { _, _ in }, onStopWatching: { _ in })
    .frame(width: 480, height: 420)
}

/// Fixtures for the previews above.
///
/// Not `FindingRowPreviewData`: those pin `publishedAt` against a fixed `now`
/// that `FindingRow`'s own previews pass back in, so the age reads sensibly.
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
