import AppKit
import SwiftUI
import OxbowKit

struct QueueView: View {
  let content: QueueContent
  let updates: UpdateModel

  /// Watching services are nil until support paths resolve, and throughout hosted tests.
  let watching: WatchingModel?
  let poller: WatchPoller?

  /// Whether the watch store is ready for Add Channel to write.
  let canAddChannel: Bool

  var imageStore: ImageStore? = nil

  /// Recorded metadata fallback for the inspector.
  var videoRecordStore: VideoRecordStore? = nil

  /// Observe the app-owned hand-off and open intake through this view's openWindow environment.
  @Binding var pendingIntake: PendingIntake?

  /// Set the watch and open AddChannelWindow; that window consumes it on appearance or change,
  /// including while already open.
  @Binding var pendingChannelEdit: Watch?

  @Environment(\.openWindow) private var openWindow

  @Environment(\.openURL) private var openURL

  @State private var selection: Set<JobID> = []

  /// Treat nil List selection as Queue, matching the initial destination.
  @State private var sidebarSelection: SidebarItem? = .queue

  @State private var hasSelectedAtLaunch = false

  /// Share one archive selection across Watching destinations. Globally unique ids resolve to
  /// nothing when absent from the visible channel.
  @State private var watchingSelection: WatchingModel.Row.ID?

  /// Cache the record for multi-selection estimates; reload on selection changes, not every
  /// progress-driven body evaluation.
  @State private var library = VideoLibrary()

  /// Remember arrival order so new cards land on top. Preserve survivors and break ties within
  /// new batches by queue position.
  @State private var selectionArrivals: [JobID] = []

  /// Keep pending removal separate from the dialog's presentation flag so dismissal need not
  /// clear the request through a computed binding.
  @State private var isConfirmingRemoval = false
  @State private var jobsPendingRemoval: Set<JobID> = []

  private var controller: QueueController? {
    if case .ready(let controller) = content { return controller }
    return nil
  }

  /// Missing-helper errors take precedence over queue-load failures.
  private var banner: (title: String, message: String)? {
    switch content {
    case .unavailable(let message):
      return ("Downloads unavailable", message)
    case .ready(let controller):
      guard let failure = controller.startFailure else { return nil }
      return ("Saved queue not loaded", failure)
    }
  }

  /// Separate builder keeps the nested split-view expression within the type checker's limits.
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

  /// Preserve surviving arrivals and append new selections in queue order. Kept outside body to
  /// reduce type-checking complexity.
  private func rememberArrivals(_ now: Set<JobID>) {
    var order = selectionArrivals.filter { now.contains($0) }
    let known = Set(order)
    for job in controller?.jobs ?? [] where now.contains(job.id) && !known.contains(job.id) {
      order.append(job.id)
    }
    selectionArrivals = order
  }

  /// Separate builder reduces body type-checking complexity.
  @ViewBuilder
  private var sidebar: some View {
      List(selection: $sidebarSelection) {
        Label("Queue", systemImage: "tray.full")
          .tag(SidebarItem.queue)
        // Apply badge before tag: the reverse order prevented selection-binding updates on
        // macOS 26. See docs/design/channel-watching.md §8.1.
        Label("Watching", systemImage: "eye")
          .badge(watching?.unreadCount ?? 0)
          .tag(SidebarItem.watching)

        // Keep channel rows expanded; a selectable DisclosureGroup header requires separate
        // selection verification.
        ForEach(watching?.channelListings ?? []) { channel in
          Label(channel.displayName, systemImage: "person.crop.circle")
            // A zero badge renders nothing.
            .badge(channel.waiting > 0 ? channel.waiting : 0)
            // Keep badge before tag to preserve selection updates; see the Watching row above.
            .tag(SidebarItem.channel(channel.login))
            .padding(.leading, 12)
            // Share channel actions with the card and inbox header.
            .contextMenu {
              ChannelActionsMenu(
                displayName: channel.displayName,
                onEdit: { editChannel(channel.login) },
                onStopWatching: { watching?.stopWatching(channel.login) })
            }
        }
      }
      .listStyle(.sidebar)
      // Constrain sidebar width so it cannot consume the queue's minimum usable space.
      .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 240)
  }

  /// Use Watching toolbar actions for both the inbox and individual channels.
  private var isShowingWatchingSide: Bool {
    switch sidebarSelection {
    case .watching, .channel: return true
    case .queue, .none: return false
    }
  }

  /// Reload watches on appearance and publish Refresh only from Watching destinations, keeping
  /// ⌘R disabled on Queue.
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

  /// Reload and edit the full Watch, shared by all three channel-action surfaces.
  private func editChannel(_ login: String) {
    watching?.refresh()
    guard let watch = watching?.watches.first(where: { $0.login == login })
    else { return }
    pendingChannelEdit = watch
    openWindow(id: OxbowApp.addChannelWindowID)
  }

  /// Resolve by login on each rebuild because sweeps replace sections. Missing channels render
  /// empty until selection falls back.
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
      // Show download-blocking warnings above update notices.
      if updates.state != .idle {
        UpdateBanner(
          state: updates.state,
          onOpen: { openURL($0) },
          onDismiss: { updates.dismiss() })
        Divider()
      }
      // App-wide banners span the sidebar, detail, and inspector.
      NavigationSplitView {
        sidebar
      } detail: {
        switch sidebarSelection {
        case .watching:
          watchingSide { watchingPane }
        case .channel(let login):
          watchingSide { channelPane(login) }
        // No catch-all, deliberately: `case .queue, .none:` would absorb any new
        // destination and land it silently on the queue. Written out, the compiler
        // finds every site that must learn about it.
        case .queue:
          queue
        case .none:
          queue
        }
      }
    }
    // Attach the inspector below the banners, on the split view.
    .task(id: selection) {
      library = videoRecordStore.flatMap { try? $0.load() } ?? VideoLibrary()
    }
    .onChange(of: selection) { _, now in rememberArrivals(now) }
    // The inspector is permanently open; see docs/design/inspector.md §7.
    .inspector(isPresented: .constant(true)) {
      InspectorPane(
        subject: InspectorSubject.resolve(
          destination: sidebarSelection,
          queueSelection: selection,
          watchingSelection: watchingSelection,
          sections: watching?.sections ?? [],
          library: library,
          arrivals: selectionArrivals,
          jobs: controller?.jobs ?? []),
        controller: controller,
        record: videoRecordStore,
        imageStore: imageStore)
    }
    // Minimum width includes queue content (480), sidebar (180), and the permanent inspector
    // (260).
    .frame(minWidth: 480 + 180 + 260, minHeight: 320)
    .toolbar {
      // Show Add Download on Queue and Add Channel on Watching. Finding rows have their own Add
      // action.
      if isShowingWatchingSide {
        ToolbarItem(placement: .primaryAction) {
          Button {
            Task { await poller?.refreshNow() }
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          // Disable Refresh during a sweep because refreshNow() returns without queuing
          // another. Also disable before the poller exists.
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
          .help("Add Download (⌘N)")
          .disabled(controller == nil)
        }
      }

    }
    // Notification clicks select Watching only when this view exists. With the queue window
    // closed, the click activates the app but does not reopen it.
    .onChange(of: WatchingReveal.shared.requests) {
      sidebarSelection = .watching
    }
    // Fall back to the inbox after removing the selected channel. Observe logins rather than
    // every sweep's section changes.
    .onChange(of: watching?.channelListings.map(\.login) ?? []) { _, logins in
      if case .channel(let login) = sidebarSelection, !logins.contains(login) {
        sidebarSelection = .watching
      }
    }
    // Apply results when sweeping ends, after automatic submissions and markSubmitted writes
    // finish. Observing results earlier could expose actionable duplicates. Fire initially too,
    // in case the sweep completed before this view appeared.
    .onChange(of: poller?.isSweeping, initial: true) { _, isSweeping in
      guard isSweeping == false, let results = poller?.results else { return }
      watching?.apply(results)
    }
    // Forward queue changes to updateJobs, which filters progress-only updates. Keep this
    // frequently called closure cheap.
    .onChange(of: controller?.jobs) {
      watching?.updateJobs(controller?.jobs ?? [])
    }
    .task { watching?.updateJobs(controller?.jobs ?? []) }
    // Choose the launch destination after persisted jobs arrive.
    .onChange(of: controller?.jobs) { selectAtLaunch(controller?.jobs ?? []) }
    .task { selectAtLaunch(controller?.jobs ?? []) }
    // Opening an already-visible intake only refocuses it; onAppear does not consume the new
    // finding until close/reopen. This hand-off currently retains that limitation.
    .onChange(of: pendingIntake) { _, newValue in
      guard newValue != nil else { return }
      openWindow(id: OxbowApp.intakeWindowID)
    }
  }

  /// Without a controller, show an empty queue with Add disabled; the banner supplies the
  /// reason.
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
      // System row banding separates jobs whose expanded heights differ.
      .alternatingRowBackgrounds()
      .onDeleteCommand { requestRemoval(of: selection, from: controller) }
      // Selection-aware context menus act on the right-clicked row or the full existing
      // selection.
      .contextMenu(forSelectionType: JobID.self) { ids in
        QueueActionButtons(
          actions: actions(from: controller), ids: ids, presentation: .contextMenu)
      } primaryAction: { ids in
        guard let id = ids.first, ids.count == 1 else { return }
        openWindow(id: OxbowApp.infoWindowID, value: id)
      }
      // Publish actions only while Queue is visible; switching to Watching disables the
      // Downloads menu.
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
      // Expand the empty-state branch so banners remain under the toolbar instead of centring
      // with the stack.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - Actions

  /// Route menu removal through the same running-job confirmation as Delete.
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

  /// Select a running job, otherwise the first row, once jobs arrive at launch. Set the flag
  /// even if already selected so later deliberate deselection stays empty.
  private func selectAtLaunch(_ jobs: [Job]) {
    guard !hasSelectedAtLaunch, !jobs.isEmpty else { return }
    hasSelectedAtLaunch = true
    guard selection.isEmpty else { return }
    guard let pick = jobs.first(where: { $0.status == .running }) ?? jobs.first
    else { return }
    selection = [pick.id]
  }

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

  /// Name a single running job; count multiple jobs in the removal confirmation.
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
