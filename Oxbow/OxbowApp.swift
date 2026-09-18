import AppKit
import SwiftUI
import OxbowKit

@main
struct OxbowApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var content: QueueContent?

  /// Start update checks independently of helper discovery.
  @State private var updates = UpdateModel.live()

  /// Construct after resolving support paths, only in a user session.
  @State private var poller: WatchPoller?

  /// Use the same watch-store path for polling and UI state.
  @State private var watching: WatchingModel?

  /// Retain the resolved store for AddChannelWindow; nil outside a user session.
  @State private var watchStore: WatchStore?

  /// Resolve the video record once for Get Info's fallback instead of doing directory-creating
  /// I/O on every window open.
  @State private var videoRecordStore: VideoRecordStore?

  @State private var imageStore: ImageStore?

  /// Hand off a finding to the single intake Window; it clears the value after applying it.
  @State private var pendingIntake: PendingIntake?

  /// Hand off a watch to the single AddChannelWindow before it appears.
  @State private var pendingChannelEdit: Watch?

  private let about = AboutInfo.main

  /// Retain preferences instead of constructing them on every scene body evaluation.
  @State private var addChannelPreferences = Preferences()

  var body: some Scene {
    // Window enforces a single queue window. QueueHost separately guarantees one engine and
    // controller.
    Window("Oxbow", id: Self.queueWindowID) {
      Group {
        // Use QueueView for missing-helper launches too, retaining toolbar and banner chrome.
        if let content {
          QueueView(
            content: content, updates: updates, watching: watching, poller: poller,
            canAddChannel: watchStore != nil, imageStore: imageStore,
            videoRecordStore: videoRecordStore,
            pendingIntake: $pendingIntake,
            pendingChannelEdit: $pendingChannelEdit)
        } else {
          // Wait for startup reconciliation before exposing the queue or permitting enqueue.
          ProgressView().frame(minWidth: 480, minHeight: 320)
        }
      }
      .task { await setUp() }
      // Screenshot framing only. Has to be AppKit rather than `.defaultSize`
      // below, which frame restoration overrides — see `ScreenshotFixture`.
      #if DEBUG
      .background {
        ScreenshotWindowSizer()
        ScreenshotIntakeOpener(windowID: Self.intakeWindowID)
        ScreenshotWindowFocus()
      }
      #endif
      // Check independently of engine setup. Gate hosted tests to avoid live requests and
      // preference writes.
      .task {
        guard AppComposition.isUserSession else { return }
        await updates.checkAutomatically()
      }
      // Poll independently of engine setup, but never in the XCTest host process.
      .task {
        guard AppComposition.isUserSession else { return }
        guard poller == nil else { return }
        guard let support = try? AppComposition.defaultSupportDirectory() else { return }
        let store = WatchStore(fileURL: AppComposition.watchStoreURL(supportDirectory: support))
        watching = WatchingModel(
          store: store,
          videoRecordStore: VideoRecordStore(
            fileURL: AppComposition.videoRecordURL(supportDirectory: support)),
          // QueueView observes this hand-off and opens the window through its environment.
          openIntake: { archive, watch in
            pendingIntake = PendingIntake(archiveID: archive.id, settings: watch.settings)
          },
          // Queue with the watch's frozen settings. Nil means success; a string explains
          // refusal.
          queue: { archive, watch in
            guard case .ready(let controller) = await QueueHost.shared.ready() else {
              return "Oxbow's download engine is not available."
            }
            let result = await ArchiveSubmission.submit([archive], for: watch, into: controller)
            return result.failures[archive.id]
          },
          // Do not use VolumeSpace.nearestExisting: an unmounted /Volumes path resolves to the
          // boot volume and would misclassify an offline file as deleted.
          fileAnswer: { url in
            ArchiveRowState.FileAnswer.resolve(
              url,
              fileExists: { FileManager.default.fileExists(atPath: $0.path) },
              folderExists: { FileManager.default.fileExists(atPath: $0.path) })
          },
          // Read imageStore at call time; it is constructed after the model.
          purgeImages: { referenced in
            Task { await imageStore?.purge(keeping: referenced) }
          },
          payloads: PayloadStore(
            directory: AppComposition.payloadDirectory(supportDirectory: support)))
        watchStore = store
        imageStore = ImageStore.live(
          directory: AppComposition.imageStoreURL(supportDirectory: support))
        videoRecordStore = VideoRecordStore(
          fileURL: AppComposition.videoRecordURL(supportDirectory: support))
        // Fixture channels are fictional: load them for display, but do not poll Twitch.
        #if DEBUG
        guard ScreenshotFixture.directory == nil else { return }
        #endif
        poller = WatchPoller.live(supportDirectory: support)
        poller?.start()
      }
    }
    // Include the sidebar's 180pt ideal width in the default window size.
    .defaultSize(width: 900, height: 480)
    .windowResizability(.contentMinSize)
    .commands {
      // Replace the stock About panel with access to bundled licence documents.
      CommandGroup(replacing: .appInfo) {
        AboutCommand(applicationName: about.applicationName)
        // Manual checks report up-to-date status and failures; automatic checks are silent
        // unless an update exists.
        CheckForUpdatesCommand(updates: updates)
      }
      // Use ⌘N for the same single intake window as the toolbar + button.
      CommandGroup(replacing: .newItem) {
        AddDownloadCommand(isEnabled: controller != nil)
      }
      DownloadsCommands()
      WatchingCommands()
    }

    // A single intake Window sizes independently and refocuses existing work instead of
    // duplicating forms and fetches.
    Window("Add Download", id: Self.intakeWindowID) {
      if let controller {
        IntakeWindow(controller: controller, pendingIntake: $pendingIntake)
      }
    }
    .defaultSize(width: 560, height: 680)
    .windowResizability(.contentMinSize)
    .defaultPosition(.center)
    // Do not restore an empty intake on launch; its in-memory input does not survive quitting.
    .restorationBehavior(.disabled)

    // A single Add Channel window sizes independently and avoids duplicate lookups.
    Window("Add Channel", id: Self.addChannelWindowID) {
      if let watchStore {
        AddChannelWindow(
          store: watchStore, preferences: addChannelPreferences,
          pendingEdit: $pendingChannelEdit,
          // Reload Watching after another store handle writes the watch list.
          onClose: { watching?.refresh() },
          // Poll the new watch immediately to discover and act on findings.
          onSaved: { Task { await poller?.refreshNow() } })
      }
    }
    .defaultSize(width: 480, height: 640)
    .windowResizability(.contentMinSize)
    .defaultPosition(.center)
    .restorationBehavior(.disabled)

    // One window per InfoTarget: repeat requests refocus it; different videos can be compared
    // side by side.
    WindowGroup(id: Self.infoWindowID, for: InfoTarget.self) { $target in
      if let target, let controller {
        JobInfoWindow(target: target, controller: controller, record: videoRecordStore)
      }
    }
    .defaultSize(width: 460, height: 620)
    .windowResizability(.contentMinSize)
    // Do not restore info windows pointing at jobs removed or reconciled since quit.
    .restorationBehavior(.disabled)

    // Single-instance About window, opened through the custom menu item.
    Window("About \(about.applicationName)", id: Self.aboutWindowID) {
      AboutView(info: about)
    }
    .windowResizability(.contentSize)
    .commandsRemoved()
    .defaultPosition(.center)
    .restorationBehavior(.disabled)

    // Settings supplies the system menu item and ⌘, shortcut. Unverified: whether macOS 26 adds
    // its menu icon automatically; see docs/design/settings.md §7.1.
    Settings {
      SettingsView()
    }
  }

  static let aboutWindowID = "about"

  static let queueWindowID = "queue"

  static let infoWindowID = "info"

  static let intakeWindowID = "intake"

  static let addChannelWindowID = "addChannel"

  private var controller: QueueController? {
    if case .ready(let controller) = content { return controller }
    return nil
  }

  private func setUp() async {
    guard content == nil else { return }
    content = await QueueHost.shared.ready()
  }
}

/// A View provides the openWindow environment value unavailable to App itself.
private struct AddDownloadCommand: View {
  let isEnabled: Bool

  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button {
      openWindow(id: OxbowApp.intakeWindowID)
    } label: {
      Label("Add Download…", systemImage: "plus")
    }
    .keyboardShortcut("n")
    .disabled(!isEnabled)
  }
}

/// Open the queue before checking so the result is visible even when all windows were closed.
private struct CheckForUpdatesCommand: View {
  let updates: UpdateModel

  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button {
      openWindow(id: OxbowApp.queueWindowID)
      Task { await updates.checkManually() }
    } label: {
      Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
    }
  }
}

private struct AboutCommand: View {
  let applicationName: String

  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button {
      openWindow(id: OxbowApp.aboutWindowID)
    } label: {
      Label("About \(applicationName)", systemImage: "info.circle")
    }
  }
}

/// Delay termination with terminateLater until async shutdown kills helper process groups and
/// flushes the pending queue save. applicationWillTerminate cannot await this work. Concurrent
/// cancellation bounds the wait to one grace period.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Register the notification delegate synchronously before launch completes, including
  /// missing-helper launches, to receive cold-launch responses. Then start idempotent QueueHost
  /// resolution without waiting.
  func applicationDidFinishLaunching(_ notification: Notification) {
    QueueHost.shared.registerNotificationDelegate()
    Task { _ = await QueueHost.shared.ready() }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Quitting must not start engine resolution merely to check whether shutdown is needed.
    guard let controller = QueueHost.shared.resolvedController else { return .terminateNow }
    Task {
      await controller.shutDown()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
