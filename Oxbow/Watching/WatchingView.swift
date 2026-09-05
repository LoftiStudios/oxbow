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
  let onAdd: (ChannelArchive, WatchingModel.Section) -> Void
  let onIgnore: (ChannelArchive, WatchingModel.Section) -> Void

  var body: some View {
    if sections.isEmpty {
      // Not "loading" and not "checking" — there is a real difference between
      // no results yet and nothing to check in the first place, and until the
      // next plan adds a way to watch a channel from here, this *is* that
      // second case for everyone who opens it.
      ContentUnavailableView {
        Label("No channels watched yet", systemImage: "eye")
      }
    } else {
      List {
        ForEach(sections) { section in
          Section(section.displayName) {
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

#Preview("Two channels, findings") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        archives: [WatchingViewPreviewData.normal, WatchingViewPreviewData.longTitle],
        failure: nil),
      WatchingModel.Section(
        login: "quietchannel", displayName: "A Quiet Channel",
        archives: [], failure: nil),
    ],
    onAdd: { _, _ in }, onIgnore: { _, _ in })
  .frame(width: 480, height: 420)
}

#Preview("One channel failed") {
  WatchingView(
    sections: [
      WatchingModel.Section(
        login: "leighxp", displayName: "LeighXP",
        archives: [WatchingViewPreviewData.normal], failure: nil),
      WatchingModel.Section(
        login: "brokenchannel", displayName: "A Broken Channel",
        archives: [],
        failure: "The response did not include the expected video list."),
    ],
    onAdd: { _, _ in }, onIgnore: { _, _ in })
  .frame(width: 480, height: 420)
}

#Preview("No channels watched") {
  WatchingView(sections: [], onAdd: { _, _ in }, onIgnore: { _, _ in })
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
