import AppKit
import SwiftUI
import OxbowKit

/// A watched channel, as a card: a large avatar, its name, what it is frozen
/// to download at (§3.2), a mark for automatic downloading when it is on, a
/// notice when its downloads live on a volume that is not mounted, and — the
/// only place either is offered — Edit and Stop Watching.
///
/// **Replaces `SectionHeader`.** `docs/design/channel-history.md` §2: a
/// channel is a card with contents, not a line item in a list. This is that
/// card's own header — `WatchingView` still lists the channel's rows below
/// it — so a watched channel finally looks like a thing that has contents
/// rather than a compact line above them.
///
/// **No confirmation dialog on Stop Watching.** Unlike removing a queued
/// download, this destroys nothing: it edits `watches.json` alone, and
/// every file a past download produced is untouched. A confirmation here
/// would be warning about a loss that does not happen, so the wording
/// carries that instead of a dialog — both the button's own label and its
/// tooltip say plainly that downloaded files stay put.
struct ChannelCard: View {
  let section: WatchingModel.Section
  let imageStore: ImageStore?
  /// Why this channel's automatic downloading is paused this sweep, or nil
  /// when it is not — `demotions[section.login]` from the call site.
  let demotionReason: AutoDownloadPolicy.Reason?
  let onEdit: () -> Void
  let onStopWatching: () -> Void

  /// The volume name to name in `disconnectedVolumeNotice`, or nil when no
  /// row's file came back unverifiable.
  ///
  /// `docs/design/channel-history.md` §4.2: a disconnected volume is one
  /// condition with two expressions, not two different facts. `ArchiveRow`
  /// already says so per row — `.unverifiable`'s glyph carries the volume's
  /// name in a hover tooltip — but a tooltip is not an honest place to put
  /// "your library might be gone": it only reaches whoever happens to
  /// hover, and someone skimming several watched channels never does. This
  /// states the same condition once, plainly, at the level a whole
  /// channel's rows share it, derived from those rows rather than asked for
  /// separately. If somehow more than one volume is involved, this names
  /// the first and does not invent a summary across them — that would be a
  /// claim nothing here actually computed.
  private var disconnectedVolume: String? {
    Self.disconnectedVolume(in: section.rows)
  }

  /// Pulled out of the computed property above so `ChannelCardTests` can
  /// exercise it without building a whole `ChannelCard` — the same reason
  /// `NotificationDecision` and `ArchiveRowState` are pure static functions
  /// rather than instance members.
  static func disconnectedVolume(in rows: [WatchingModel.Row]) -> String? {
    for row in rows {
      if case .unverifiable(let volumeName) = row.state { return volumeName }
    }
    return nil
  }

  /// Edit and Stop Watching, defined once.
  ///
  /// **Rendered by both the ‹…› button and the right-click.** Two copies of
  /// the same pair is two things to keep in step, and the first divergence
  /// would be a menu that offers something the right-click does not — or,
  /// worse, a Stop Watching that exists in one and not the other.
  @ViewBuilder
  private var actions: some View {
    // Above Stop Watching, matching how a Mac menu orders a reversible
    // action before a destructive-adjacent one — this changes settings,
    // that removes the channel entirely.
    Button {
      onEdit()
    } label: {
      Label("Edit…", systemImage: "pencil")
    }
    .help("Change \(section.displayName)'s frozen settings.")

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

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Centred against the avatar rather than top-aligned, and the avatar
      // sized so the two read as one block — the shape Music gives an album:
      // art on the left, a strong title and a quiet metadata line beside it,
      // vertically balanced. 88pt is the height of that text block plus a
      // little, which is what the mockup drew.
      HStack(alignment: .center, spacing: 14) {
        ChannelAvatar(url: section.avatarURL, store: imageStore, size: 88)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(section.displayName)
              .font(.title)
              .fontWeight(.semibold)
            // Only shown when it is actually on: off is the default and the
            // ordinary case, and marking every quiet channel "Manual" would
            // be the loud thing `WatchingView`'s own doc comment already
            // argues against for a "no new videos" row under every quiet
            // section.
            if section.downloadsAutomatically {
              if let demotionReason {
                // A different glyph and colour from the steady "on" state
                // below, not just a different tooltip — this has to read at
                // a glance, without hovering, as something other than the
                // ordinary automatic-downloading mark (requirement: a
                // demoted watch must be visibly distinguishable from one
                // quietly working as intended, never only from a channel
                // with nothing new).
                Label("Downloads paused", systemImage: "bolt.slash.fill")
                  .labelStyle(.iconOnly)
                  .foregroundStyle(.orange)
                  .help(demotionReason.sentence)
              } else {
                Label("Downloads automatically", systemImage: "bolt.fill")
                  .labelStyle(.iconOnly)
                  .foregroundStyle(.blue)
                  // Present tense and true: automatic downloading is real
                  // now — findings this channel turns up queue on their own,
                  // without Add, as long as the destination stays reachable
                  // and the disk stays above the floor set in Settings. The
                  // demoted branch above is what covers the moment either of
                  // those stops holding.
                  .help("""
                    Set to download automatically. New archives from this \
                    channel are queued and downloaded on their own, without \
                    waiting for Add.
                    """)
              }
            }
            Spacer(minLength: 0)
          }
          if !section.settingsSummary.isEmpty {
            // One quiet line under a strong one, the way "Alternative · 2026
            // · Lossless" sits under an album's title: this is reference
            // material, not something to read every time.
            Text(section.settingsSummary)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }
        // **The visible route to Edit and Stop Watching.** Both lived only
        // in the right-click until now, which the app's own author could not
        // find — a per-item menu button is what a Mac uses for actions that
        // matter but are not the primary one, and it costs a control's
        // width. The right-click is kept: this adds a way in, it does not
        // move one.
        Menu {
          actions
        } label: {
          Label("Channel actions", systemImage: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .fixedSize()
        .accessibilityLabel("Actions for \(section.displayName)")
      }
      if let disconnectedVolume {
        disconnectedVolumeNotice(disconnectedVolume)
      }
    }
    .padding(.vertical, 8)
    .textCase(nil)
    .contextMenu { actions }
  }

  /// Visually distinct from the demotion mark above (and from
  /// `WatchingView.DemotionRow`), on purpose. Those are about *future*
  /// downloads pausing — a policy choice that resolves itself the moment
  /// the destination or the disk does. This is about downloads that already
  /// happened, whose whereabouts Oxbow currently cannot vouch for at all. A
  /// person has to be able to tell "will this download" apart from "do I
  /// still have this," so the notice gets its own icon and its own sentence
  /// rather than borrowing the paused-bolt's colour or shape.
  private func disconnectedVolumeNotice(_ volume: String) -> some View {
    Label {
      Text("\(volume) is disconnected. Oxbow can't tell whether downloads on it are still there.")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "externaldrive.badge.questionmark")
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}

#Preview("Avatar, downloads automatically") {
  List {
    Section {
      Text("Rows go here")
    } header: {
      ChannelCard(
        section: WatchingModel.Section(
          login: "leighxp", displayName: "LeighXP",
          avatarURL: ChannelCardPreviewData.avatarURL,
          rows: [], failure: nil,
          settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
          downloadsAutomatically: true),
        imageStore: nil, demotionReason: nil,
        onEdit: {}, onStopWatching: {})
    }
  }
  .frame(width: 480, height: 220)
}

#Preview("No avatar") {
  List {
    Section {
      Text("Rows go here")
    } header: {
      ChannelCard(
        section: WatchingModel.Section(
          login: "quietchannel", displayName: "A Quiet Channel",
          rows: [], failure: nil,
          settingsSummary: "Video · Up to 720p · Archive",
          downloadsAutomatically: false),
        imageStore: nil, demotionReason: nil,
        onEdit: {}, onStopWatching: {})
    }
  }
  .frame(width: 480, height: 220)
}

#Preview("Demoted, below floor") {
  List {
    Section {
      Text("Rows go here")
    } header: {
      ChannelCard(
        section: WatchingModel.Section(
          login: "leighxp", displayName: "LeighXP",
          rows: [], failure: nil,
          settingsSummary: "Video + chat · Best available · Medium chat · Archive",
          downloadsAutomatically: true),
        imageStore: nil,
        demotionReason: .belowFloor(needed: 2_600_000_000, available: 12_000_000_000, floor: 49_000_000_000),
        onEdit: {}, onStopWatching: {})
    }
  }
  .frame(width: 480, height: 220)
}

// New: `disconnectedVolume` reads the same fact `ArchiveRow`'s `.unverifiable`
// badge shows per row (§4.2) and states it plainly at the channel level,
// rather than only in a tooltip a person has to find.
#Preview("Disconnected volume") {
  List {
    Section {
      Text("Rows go here")
    } header: {
      ChannelCard(
        section: WatchingModel.Section(
          login: "leighxp", displayName: "LeighXP",
          rows: [
            WatchingModel.Row(
              archive: ChannelCardPreviewData.normal,
              state: .unverifiable(volumeName: "Helios")),
          ],
          failure: nil,
          settingsSummary: "Video + chat · Best available · Medium chat · Downloads",
          downloadsAutomatically: false),
        imageStore: nil, demotionReason: nil,
        onEdit: {}, onStopWatching: {})
    }
  }
  .frame(width: 480, height: 260)
}

/// Fixtures for the previews above.
///
/// Not `WatchingView`'s or `ArchiveRow`'s: each file that previews against
/// `Date()` keeps its own fixtures rather than sharing one anchored to a
/// fixed instant, for the reason `WatchingViewPreviewData` already explains
/// at length — this card never threads a `now` down either, so its own
/// fixture anchors to the real clock the same way.
private enum ChannelCardPreviewData {
  static let avatarURL = URL(string: "https://static-cdn.jtvnw.net/preview.jpg")!

  static let normal = ChannelArchive(
    id: "1", title: "Indie horror night",
    duration: .seconds(3 * 3600 + 24 * 60),
    publishedAt: Date().addingTimeInterval(-12 * 86400),
    status: .recorded, thumbnailURL: nil)
}
