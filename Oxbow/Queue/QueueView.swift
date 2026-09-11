import AppKit
import SwiftUI
import OxbowKit

struct QueueView: View {
  let content: QueueContent
  let updates: UpdateModel

  /// The Watching list and the sweep that feeds it.
  ///
  /// Both optional for the same reason: `OxbowApp` builds them only once it
  /// has resolved a support directory, behind the same
  /// `AppComposition.isUserSession` guard that keeps `WatchPoller` off the
  /// network during `xcodebuild test` — see the guarded `.task` there. A
  /// test-hosted window simply sees nil here, and the Watching pane below
  /// falls back to `WatchingView`'s own empty state rather than this view
  /// having to invent a second "no data yet" state of its own.
  let watching: WatchingModel?
  let poller: WatchPoller?

  /// Whether `OxbowApp` has resolved a support directory yet, and so has a
  /// `WatchStore` ready for the Add Channel window to write to. `watching`
  /// itself would say the same thing, but reading `watching == nil` here
  /// would tie this button's enabled state to a model whose only other job
  /// is holding the sweep results — a coincidence, not a dependency this
  /// view should be built to notice if it ever stopped holding.
  let canAddChannel: Bool

  /// Handed straight through to `WatchingView` — this view never reads it.
  var imageStore: ImageStore? = nil

  /// Handed to `InspectorPane` so an expired video still renders a card.
  /// Optional for the same reason `imageStore` is.
  var videoRecordStore: VideoRecordStore? = nil

  /// A Watching finding waiting to be applied, from `OxbowApp`'s own `@State`.
  ///
  /// **This is where `WatchingModel.openIntake` actually opens anything.**
  /// The closure `OxbowApp` hands to `WatchingModel` only sets this binding —
  /// it runs inside a plain `.task`, with no `openWindow` to call — so the
  /// `.onChange` below is what turns "a finding is pending" into the intake
  /// window actually appearing, using the `openWindow` this view already has.
  @Binding var pendingIntake: PendingIntake?

  /// A watch waiting to be edited, from `OxbowApp`'s own `@State`.
  ///
  /// **Set here, not consumed here.** Unlike `pendingIntake`, nothing in
  /// this view reads the value back — it only writes it, then opens the Add
  /// Channel window, whose own `.onAppear` and `.onChange(of:)` (the latter
  /// catching a request that arrives while the window is already open — see
  /// `AddChannelWindow`'s own comment on why this one needed the second hook
  /// where `pendingIntake` below did not) apply it to `AddChannelModel` and
  /// clear it. This view already has `openWindow` and already does the
  /// identical two-step for the ordinary Add Channel toolbar button just
  /// below, so Edit reuses the same window rather than inventing a second
  /// path to it — see `WatchingView.onEdit`'s own doc comment for why.
  @Binding var pendingChannelEdit: Watch?

  /// Opens the intake window (`OxbowApp.intakeWindowID`). Intake is a window
  /// rather than a sheet on this one — see `IntakeWindow` for why — so the
  /// toolbar button hands off to the scene instead of presenting anything.
  @Environment(\.openWindow) private var openWindow

  /// Opening the release page is the update banner's whole action.
  @Environment(\.openURL) private var openURL

  @State private var selection: Set<JobID> = []

  /// Which sidebar destination is showing. Optional because `List`'s
  /// selection binding requires it — a `List` reports "nothing selected" as
  /// nil, most visibly when someone command-clicks the current row off — but
  /// the initial value is Queue, and the detail switch below treats a later
  /// nil the same way rather than showing a blank pane.
  @State private var sidebarSelection: SidebarItem? = .queue

  /// Whether the trailing inspector is open.
  ///
  /// **One flag for every destination, not one each.** A control that
  /// remembers a different answer depending on where you are standing is one
  /// you cannot predict — `docs/design/inspector.md` §7, which is §6's
  /// argument about the content applied to the chrome.
  @State private var isInspectorOpen = false

  /// The selected archive, shared by the inbox and every channel destination.
  ///
  /// **One piece of state, not one per destination** (`inspector.md` §3.2).
  /// Archive ids are unique across Twitch, so an id from one channel resolves
  /// to nothing in another rather than to the wrong row — which is what lets
  /// switching destinations need no reset step.
  ///
  /// Hoisted out of `WatchingView` and `ChannelView` rather than lifted with
  /// `focusedSceneValue`: every existing use of that idiom here is a
  /// descendant publishing to the menu bar, and a view reading what its own
  /// subtree published is a different data flow.
  @State private var watchingSelection: WatchingModel.Row.ID?

  /// The video record, for pricing a multi-selection.
  ///
  /// Held rather than read inside `body`: `VideoRecordStore.load()` is disk
  /// I/O, and `body` runs on every progress tick. Refreshed when the queue
  /// selection changes, which is the only moment the estimate is recomputed
  /// for a reason a person caused.
  @State private var library = VideoLibrary()

  /// A removal waiting on the user, and the dialog's own presentation flag.
  ///
  /// Two pieces of state rather than one optional driving a computed
  /// `Binding(get:set:)`: the binding form has to write `nil` back on dismiss,
  /// which means constructing a binding inside `body` that mutates the state
  /// `body` is reading. Separate flags keep the dismissal SwiftUI's business.
  @State private var isConfirmingRemoval = false
  @State private var jobsPendingRemoval: Set<JobID> = []

  private var controller: QueueController? {
    if case .ready(let controller) = content { return controller }
    return nil
  }

  /// The window's one explanation slot, in precedence order.
  ///
  /// A missing payload outranks a queue file that failed to load: nothing can
  /// run at all, which is the more important thing to say, and the two cannot
  /// both be true anyway — without an engine there is no load to fail.
  private var banner: (title: String, message: String)? {
    switch content {
    case .unavailable(let message):
      return ("Downloads unavailable", message)
    case .ready(let controller):
      guard let failure = controller.startFailure else { return nil }
      return ("Saved queue not loaded", failure)
    }
  }

  /// Extracted from `body`'s `switch` because the type checker gave up on
  /// it there: sixteen arguments, eight of them closures, inside a
  /// `NavigationSplitView` detail builder inside a `VStack` exceeded what it
  /// would solve in reasonable time. Splitting it out changes nothing about
  /// what is built.
  @ViewBuilder
  private var watchingPane: some View {
WatchingView(
  sections: watching?.sections ?? [],
  isSweeping: poller?.isSweeping ?? false,
  demotions: poller?.demotions ?? [:],
  selection: $watchingSelection,
  imageStore: imageStore,
  onAdd: { archive, section in
    Task { await watching?.add(archive, from: section.login) }
  },
  onAddWithOptions: { archive, section in
    watching?.openInIntake(archive, from: section.login)
  },
  onIgnore: { archive, section in watching?.ignore(archive, from: section.login) },
  onEdit: { section in editChannel(section.login) },
  onStopWatching: { section in watching?.stopWatching(section.login) },
  stopWatchingFailure: watching?.stopWatchingFailure,
  markSeenFailure: watching?.markSeenFailure,
  submissionFailure: watching?.submissionFailure)
  }

  /// Whether the visible pane is on the Watching side — the inbox or any one
  /// channel.
  ///
  /// The toolbar branches on this rather than on `== .watching` because a
  /// channel destination needs the same two buttons: `Refresh` sweeps every
  /// watched channel (there is no per-channel fetch), and `Add Channel` is how
  /// a person reaches that window at all. Left as `== .watching`, selecting a
  /// channel would swap in `Add Download` — whose own comment below says it
  /// was kept off this pane precisely so nobody reads it as acting on the
  /// visible rows.
  private var isShowingWatchingSide: Bool {
    switch sidebarSelection {
    case .watching, .channel: return true
    case .queue, .none: return false
    }
  }

  /// The two modifiers every Watching-side destination needs, applied once
  /// rather than copied into each branch.
  ///
  /// `.onAppear` re-reads `watches.json` the moment a pane becomes visible, so
  /// a channel added from the Add Channel window while Queue was showing is
  /// there the instant someone switches over, rather than waiting for the next
  /// hourly sweep — see `WatchingModel.refresh()`'s own doc comment. The Add
  /// Channel window's own close is the other half of that fix.
  ///
  /// The `focusedSceneValue` is published from inside these branches so ⌘R
  /// greys out on the Queue pane — the same "the menu follows the visible
  /// pane" rule the `queueActions` publication keeps.
  ///
  /// **A function rather than two copies.** There are two Watching-side
  /// destinations now and the pair has to be identical on both; copied, the
  /// first thing to happen is that a third destination gets one of them.
  @ViewBuilder
  private func watchingSide<Content: View>(
    @ViewBuilder _ content: () -> Content
  ) -> some View {
    content()
      .onAppear { watching?.refresh() }
      .focusedSceneValue(\.watchingActions, WatchingActions(
        canRefresh: poller != nil && poller?.isSweeping != true,
        refresh: { [poller] in await poller?.refreshNow() }))
  }

  /// Opens Add Channel in editing mode, seeded from that login's own watch.
  ///
  /// **`watching?.watches`, not a `Section`.** A section carries only what a
  /// row needs to render; `AddChannelModel.beginEditing(_:)` needs the whole
  /// `Watch`, including its `seen` set.
  ///
  /// The `refresh()` is belt-and-braces rather than load-bearing:
  /// `WatchingModel.markSeen(_:in:)` already rebuilds `watches` after it
  /// persists, so this is a no-op re-read on the normal path. Left in as cheap
  /// insurance against `watches` ever going stale again.
  ///
  /// Defined once because three places now reach it: the inbox's section
  /// header, a channel destination's card, and the sidebar row.
  private func editChannel(_ login: String) {
    watching?.refresh()
    guard let watch = watching?.watches.first(where: { $0.login == login })
    else { return }
    pendingChannelEdit = watch
    openWindow(id: OxbowApp.addChannelWindowID)
  }

  /// The destination for one watched channel.
  ///
  /// **Resolves the section by login on every rebuild rather than holding
  /// one.** A sweep replaces `sections` wholesale, so a captured section would
  /// go stale the moment one landed. A login with no section is a channel that
  /// has just been stopped — Slice E moves the selection off it; until then it
  /// renders nothing rather than crashing.
  @ViewBuilder
  private func channelPane(_ login: String) -> some View {
    if let section = watching?.sections.first(where: { $0.login == login }) {
      ChannelView(
        section: section,
        imageStore: imageStore,
        demotionReason: poller?.demotions[login],
        onAdd: { archive in Task { await watching?.add(archive, from: login) } },
        onAddWithOptions: { archive in watching?.openInIntake(archive, from: login) },
        onIgnore: { archive in watching?.ignore(archive, from: login) },
        onEdit: { editChannel(login) },
        onStopWatching: { watching?.stopWatching(login) },
        selection: $watchingSelection)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      if let banner {
        QueueBanner(title: banner.title, message: banner.message)
        Divider()
      }
      // Below the warning, never above it. A missing helper means the app
      // cannot do its job at all, which outranks news about a version that
      // would have the same problem.
      if updates.state != .idle {
        UpdateBanner(
          state: updates.state,
          onOpen: { openURL($0) },
          onDismiss: { updates.dismiss() })
        Divider()
      }
      // Both banners span this whole split view rather than sitting inside
      // the detail pane. They are about the app — a missing helper means
      // nothing can download regardless of which sidebar item is showing —
      // so putting them in the detail pane would hide "Downloads unavailable"
      // behind whichever destination happened to be selected.
      NavigationSplitView {
        List(selection: $sidebarSelection) {
          Label("Queue", systemImage: "tray.full")
            .tag(SidebarItem.queue)
          // `.badge` before `.tag`, not after — verified the hard way. With
          // `.tag` applied first, clicking this row on macOS 26 stopped
          // changing `sidebarSelection` at all: the row highlighted, an
          // AppKit selection action fired, and the binding never saw it. No
          // such regression is on record anywhere the settings.md §7 probe
          // looked, so treat this order as load-bearing rather than
          // stylistic until Apple documents otherwise.
          Label("Watching", systemImage: "eye")
            .badge(watching?.unreadCount ?? 0)
            .tag(SidebarItem.watching)

          // The watched channels, under `Watching` and belonging to it —
          // Mail's `All Inboxes` shape, which is what
          // `docs/design/watching-navigation.md` §4 specifies.
          //
          // **No disclosure triangle.** A collapsible group whose label is
          // itself a selectable row is a `DisclosureGroup` wrapping a tagged
          // label, and whether List selection reaches a tag in that position
          // is exactly the kind of thing `channel-watching.md` §8.1's
          // badge/tag regression says not to assume. Always-expanded first;
          // the triangle is worth having only if the list gets long enough
          // to want it.
          ForEach(watching?.channelListings ?? []) { channel in
            Label(channel.displayName, systemImage: "person.crop.circle")
              // Zero draws nothing. Mail's rule and this codebase's:
              // `WatchingView`'s own doc comment argues a quiet channel
              // should say nothing rather than say "none", and a column of
              // zeroes is that mistake in a smaller font. `.badge(0)` already
              // renders nothing — the ternary states the rule at the call
              // site so nobody "simplifies" it away without noticing it was
              // load-bearing.
              .badge(channel.waiting > 0 ? channel.waiting : 0)
              // `.badge()` BEFORE `.tag()`, same as `Watching` above and for
              // the same bisected reason — `channel-watching.md` §8.1. The
              // other order makes the row highlight, fire an AppKit selection
              // action, and never update the binding. Five rows here is five
              // fresh chances to reintroduce it.
              .tag(SidebarItem.channel(channel.login))
              .padding(.leading, 12)
              // The same pair the card offers, where Mail puts an account's
              // equivalents. One definition, three render sites — see
              // `ChannelActionsMenu`.
              .contextMenu {
                ChannelActionsMenu(
                  displayName: channel.displayName,
                  onEdit: { editChannel(channel.login) },
                  onStopWatching: { watching?.stopWatching(channel.login) })
              }
          }
        }
        .listStyle(.sidebar)
        // Roughly fixed, the way Mail and Finder do it, rather than left to
        // SwiftUI's default proportional split. Unconstrained, the sidebar
        // claimed close to a third of the window at minimum width, which is
        // most of what the queue below needs just to keep a job's title
        // legible.
        .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 240)
      } detail: {
        // **No catch-all.** `case .queue, .none:` used to absorb everything
        // that was not `.watching`, which for a new destination means landing
        // silently on the queue. Written out, the compiler is what finds every
        // site that has to learn about `.channel`.
        switch sidebarSelection {
        case .watching:
          watchingSide { watchingPane }
        case .channel(let login):
          watchingSide { channelPane(login) }
        case .queue:
          queue
        case .none:
          queue
        }
      }
    }
    // **On the split view, not on the `VStack` above it** —
    // `docs/design/inspector.md` §3.1. The banners span the whole window
    // because they are about the app rather than about the visible pane, so
    // they have to stay above the inspector exactly as they stay above the
    // sidebar and the detail.
    .task(id: selection) {
      library = videoRecordStore.flatMap { try? $0.load() } ?? VideoLibrary()
    }
    .inspector(isPresented: $isInspectorOpen) {
      InspectorPane(
        subject: InspectorSubject.resolve(
          destination: sidebarSelection,
          queueSelection: selection,
          watchingSelection: watchingSelection,
          sections: watching?.sections ?? [],
          library: library,
          jobs: controller?.jobs ?? []),
        controller: controller,
        record: videoRecordStore)
    }
    // 480 is the queue's own minimum, not the window's — it is what a job
    // row needs to keep its title legible, from before this view had a
    // sidebar at all. The +180 is the sidebar's ideal column width (set
    // above), added on top rather than carved out of the 480, so the detail
    // pane keeps roughly its designed minimum even if the split view ever
    // shrinks the sidebar down to its own 150pt floor. Height is untouched:
    // a sidebar costs no height.
    .frame(minWidth: 480 + 180, minHeight: 320)
    .toolbar {
      // Two different buttons behind the same placement, switched on which
      // pane is showing — never both, and never neither. `Add Download`
      // opens intake for a brand-new job, which is a Queue action, and a
      // finding row already has its own Add for adding *that* video; leaving
      // it visible next to a highlighted finding would invite the guess that
      // it acts on the row, when it does not. `Add Channel` is the reverse:
      // it is how a person reaches the window at all, including — per
      // `docs/design/channel-watching.md` §3 — the moment nothing is watched
      // yet and `WatchingView`'s own empty state has no control of its own to
      // offer. Living in this toolbar rather than in that empty state is what
      // keeps the button reachable whether the list is empty or full,
      // matching where `Add Download` already sits for the Queue pane.
      if isShowingWatchingSide {
        // Before Add Channel, so the pair reads left to right as "look
        // again" then "watch something new" — the order they are reached in.
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task { await poller?.refreshNow() }
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          // **Disabled during a sweep rather than queued behind one.**
          // `refreshNow()` does not bypass `sweep()`'s `isSweeping` guard —
          // it returns immediately, leaving the previous sweep's answer on
          // screen — so a button live during a sweep would be one that
          // silently did nothing. Disabling it says the same thing
          // honestly, and the sweeping state is already visible beside it
          // in `WatchingView`.
          //
          // `poller == nil` covers the launch window before `OxbowApp`'s
          // `.task` has built one, and the whole of `xcodebuild test`,
          // where it is never built at all.
          .disabled(poller == nil || poller?.isSweeping == true)
          .help("Check the watched channels for new archives now")
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            openWindow(id: OxbowApp.addChannelWindowID)
          } label: {
            Label("Add Channel", systemImage: "plus")
          }
          .help("Watch a Twitch channel for new archives")
          .disabled(!canAddChannel)
        }
      } else {
        ToolbarItem(placement: .primaryAction) {
          Button {
            openWindow(id: OxbowApp.intakeWindowID)
          } label: {
            Label("Add Download", systemImage: "plus")
          }
          // Kept alongside ⌘N deliberately: the shortcut is the fast path for
          // people who know it, and the button is how everyone else finds the
          // feature at all.
          .help("Add Download (⌘N)")
          .disabled(controller == nil)
        }
      }

      // **Outside the branch above**: the inspector belongs to the window,
      // not to one pane, so unlike Refresh / Add Channel / Add Download it is
      // present wherever you are standing.
      //
      // ⌥⌘I, never ⌘I. ⌘I is Get Info and opens the window it always has —
      // the two answer different questions (`inspector.md` §2) and the
      // shortcuts have to say so.
      ToolbarItem(placement: .primaryAction) {
        Button {
          isInspectorOpen.toggle()
        } label: {
          Label("Inspector", systemImage: "sidebar.trailing")
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .help("Show or hide details for what is selected (⌥⌘I)")
      }
    }
    // Clicking a "new archives are waiting" notification lands here — see
    // `WatchingReveal` for why that click cannot simply set state on
    // `OxbowApp` the way every other hand-off in this view does.
    //
    // **Only selects the pane; it does not open the window.** If the queue
    // window is closed there is no `QueueView` to observe this, so the click
    // activates Oxbow and nothing more — the same as the existing
    // "Download finished" banner for a job whose files have moved. Fixing
    // that means an always-present scene to hold the `openWindow` call, and
    // is not worth one on its own.
    .onChange(of: WatchingReveal.shared.requests) {
      sidebarSelection = .watching
    }
    // A destination pointed at a watch that no longer exists renders nothing
    // and offers nothing — and Stop Watching is reachable from the sidebar row
    // itself now, so this is not a rare path. Falls back to the inbox, which
    // is always there.
    //
    // Keyed on the logins rather than on `sections`: a sweep rewrites every
    // section on every poll, and comparing those would run this on each one.
    // The only change that matters here is a channel appearing or leaving.
    .onChange(of: watching?.channelListings.map(\.login) ?? []) { _, logins in
      if case .channel(let login) = sidebarSelection, !logins.contains(login) {
        sidebarSelection = .watching
      }
    }
    // Keyed on `isSweeping` falling to `false`, not on `results` changing.
    //
    // `WatchPoller.sweep()` publishes `results` *before* `actOnFindings`
    // runs — awaiting a metadata fetch per archive it is about to submit —
    // and only sets `isSweeping = false` once that has finished. Watching
    // `results` directly used to mean this view (and `WatchingModel.apply`)
    // almost always rendered mid-submission, since SwiftUI re-renders on the
    // `results` mutation well before the submissions it is about to trigger
    // have landed: a row for an archive already being downloaded stayed
    // listed as un-actioned for up to the length of that fetch, and a
    // person pressing Add on it got a second job for the same video, since
    // intake deliberately runs no duplicate guard of its own. Gating on
    // `isSweeping` instead means this only applies once `markSubmitted`'s
    // writes have actually happened, so the rows this view shows already
    // reflect them.
    //
    // `initial: true` for the identical reason the old trigger needed it:
    // `poller` and `watching` are built by `OxbowApp` independently of when
    // this view appears, and a sweep can finish — `isSweeping` already back
    // to `false` — before this view exists to observe the transition. Firing
    // once on appear regardless of the current value replays whatever the
    // last sweep already settled, the same way the old trigger replayed
    // `results`.
    .onChange(of: poller?.isSweeping, initial: true) { _, isSweeping in
      guard isSweeping == false, let results = poller?.results else { return }
      watching?.apply(results)
    }
    // Republishes the rows every time the queue's jobs change, so a job
    // starting or finishing reaches the pane immediately rather than
    // waiting for the next hourly sweep — see `WatchingModel.updateJobs`'s
    // own doc comment.
    //
    // This fires far more often than that reads: `QueueEngine.publish()` is
    // un-debounced and `Step.progress` is part of `Step`'s `Equatable`, so a
    // running download trips this on every helper status line. `updateJobs`
    // is where that flood is absorbed — it compares the handful of facts a
    // row can turn on and returns without rebuilding when they are the same.
    // Keep the cheap side of that pairing here: this closure must stay a
    // hand-off, never grow work of its own.
    .onChange(of: controller?.jobs) {
      watching?.updateJobs(controller?.jobs ?? [])
    }
    .task { watching?.updateJobs(controller?.jobs ?? []) }
    // See `pendingIntake`'s own doc comment above: this is the one place that
    // turns a finding's Add into the intake window actually opening. If the
    // window is already open, `openWindow` just re-focuses it — `Window`'s
    // own single-instance guarantee — and `IntakeWindow.onAppear` does not
    // fire a second time, so a finding Added while intake was already open on
    // a different video would sit unconsumed until the next close and
    // reopen. Accepted rather than fixed here: `onAppear` firing only on
    // genuine appearance is a SwiftUI `Window` scene's normal behaviour, not
    // a hook this view can ask for a second time, and clicking Add while a
    // different download is already mid-edit in an open intake window is a
    // narrow enough case that a future close/reopen recovering it is an
    // acceptable cost.
    .onChange(of: pendingIntake) { _, newValue in
      guard newValue != nil else { return }
      openWindow(id: OxbowApp.intakeWindowID)
    }
  }

  /// The queue itself. With no controller there are no jobs, so this is the
  /// empty state with its action disabled — the banner above it says why.
  @ViewBuilder
  private var queue: some View {
    if let controller, !controller.jobs.isEmpty {
      List(selection: $selection) {
        ForEach(controller.jobs) { job in
          JobRow(
            job: job,
            onCancel: { Task { await controller.cancel(job: job.id) } },
            onRetryJob: { Task { await controller.retry(job: job.id) } },
            onRetryStep: { step in Task { await controller.retry(step: step) } },
            onRevealRetainedFiles: { id in Task { await controller.revealRetainedFiles(for: id) } },
            checkRevealTarget: { id in await controller.revealTarget(for: id) },
            retainedBytes: { id in await controller.retainedBytes(for: id) })
          .tag(job.id)
        }
      }
      // The system's own alternating row colours, not a colour of our own:
      // rows here vary wildly in height — a collapsed single-step job is one
      // line, an expanded composite is five — and banding is what lets the eye
      // tell where one job ends and the next begins. It costs nothing when
      // there is one job, since the first row is always the unshaded one.
      .alternatingRowBackgrounds()
      // Delete on the selection, which is what a Mac list does. Removal is the
      // thing this window had no way to do at all: every job ever enqueued
      // stayed on screen forever.
      .onDeleteCommand { requestRemoval(of: selection, from: controller) }
      // `forSelectionType:` rather than a per-row `.contextMenu`, so
      // right-clicking a row selects it first and a right-click on a
      // multi-row selection acts on all of it — both of which a per-row menu
      // gets wrong.
      .contextMenu(forSelectionType: JobID.self) { ids in
        QueueActionButtons(
          actions: actions(from: controller), ids: ids, presentation: .contextMenu)
      } primaryAction: { ids in
        // `primaryAction` is the double-click. Get Info, matching ⌘I — the
        // only gesture on a row that had no meaning, and the one Finder gives
        // to the same action.
        guard let id = ids.first, ids.count == 1 else { return }
        openWindow(id: OxbowApp.infoWindowID, value: id)
      }
      // Published for the menu bar. This sits inside the Queue detail pane,
      // so switching the sidebar to Watching tears it down and the Downloads
      // menu greys out — even though the queue still holds jobs. That is
      // accepted, not missed: the menu follows the visible pane, the same way
      // its items are already hidden or disabled based on what is selected
      // within the list. `focusedSceneValue` over `focusedValue` only buys
      // independence from keyboard focus inside this pane, not independence
      // from which pane is showing.
      .focusedSceneValue(\.queueActions, actions(from: controller))
      .confirmationDialog(
        removalConfirmationTitle(for: jobsPendingRemoval, from: controller),
        isPresented: $isConfirmingRemoval)
      {
        Button("Remove", role: .destructive) {
          remove(jobsPendingRemoval, from: controller)
        }
        Button("Cancel", role: .cancel) { jobsPendingRemoval = [] }
      } message: {
        Text("The download will stop. Files already saved are not deleted.")
      }
    } else {
      ContentUnavailableView {
        Label("No downloads", systemImage: "tray")
      } description: {
        Text("Add a Twitch VOD to get started.")
      } actions: {
        Button("Add Download…") { openWindow(id: OxbowApp.intakeWindowID) }
          .disabled(controller == nil)
      }
      // Fills the space the `List` branch would, so the `VStack` above has a
      // child that expands. Without it the stack's children total less than
      // the window and get centred as a block — which left the update banner
      // floating in the middle of an empty window instead of sitting under
      // the toolbar. `ContentUnavailableView` still centres its own content
      // inside this, so the empty state looks unchanged.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - Actions

  /// The queue's actions, bound to this controller.
  ///
  /// Removal goes back through `requestRemoval` rather than straight to the
  /// controller, so a Remove from the menu bar gets the same confirmation over
  /// a running download that the Delete key does.
  private func actions(from controller: QueueController) -> QueueActions {
    QueueActions(
      jobs: controller.jobs,
      selection: selection,
      remove: { requestRemoval(of: $0, from: controller) },
      retry: { job in Task { await controller.retry(job: job) } },
      cancel: { job in Task { await controller.cancel(job: job) } },
      showInfo: { openWindow(id: OxbowApp.infoWindowID, value: $0) })
  }

  // MARK: - Removal

  /// Removes immediately, or asks first when something is still running.
  ///
  /// The confirmation is not for the row — a row is cheap to lose — it is for
  /// the work. Removing a running job kills its helper, and a two-hour chat
  /// render deserves better than a mis-hit Delete key. Nothing settled asks.
  private func requestRemoval(of ids: Set<JobID>, from controller: QueueController) {
    guard !ids.isEmpty else { return }

    let running = controller.jobs.filter { ids.contains($0.id) && $0.status == .running }
    guard running.isEmpty else {
      jobsPendingRemoval = ids
      isConfirmingRemoval = true
      return
    }
    remove(ids, from: controller)
  }

  private func remove(_ ids: Set<JobID>, from controller: QueueController) {
    jobsPendingRemoval = []
    selection.subtract(ids)
    Task { await controller.remove(jobs: ids) }
  }

  /// Names what is about to be stopped, rather than asking abstractly. One
  /// running job is worth naming; several are worth counting.
  private func removalConfirmationTitle(
    for ids: Set<JobID>,
    from controller: QueueController)
    -> String
  {
    let running = controller.jobs.filter { ids.contains($0.id) && $0.status == .running }
    guard let only = running.first, running.count == 1 else {
      return "Remove \(running.count) downloads that are still running?"
    }
    return "Remove “\(only.title)” while it is still downloading?"
  }
}

#Preview("Helper missing") {
  QueueView(
    content: .unavailable("""
    The TwitchDownloaderCLI helper is not embedded in this build. Build it \
    with the dotnet publish command in docs/development.md, then build the \
    app again.
    """),
    updates: UpdateModel { .upToDate },
    watching: nil,
    poller: nil,
    canAddChannel: false,
    pendingIntake: .constant(nil),
    pendingChannelEdit: .constant(nil))
  .frame(width: 720, height: 420)
}

#Preview("Update available") {
  let updates = UpdateModel {
    .available(
      ReleaseVersion("0.3.0")!,
      URL(string: "https://github.com/LoftiStudios/oxbow/releases/tag/v0.3.0")!)
  }
  return QueueView(
    content: .unavailable("No helper in this build."),
    updates: updates,
    watching: nil,
    poller: nil,
    canAddChannel: false,
    pendingIntake: .constant(nil),
    pendingChannelEdit: .constant(nil))
    .frame(width: 720, height: 420)
    .task { await updates.checkAutomatically() }
}
