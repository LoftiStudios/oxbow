import AppKit
import SwiftUI
import OxbowKit

@main
struct OxbowApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var content: QueueContent?

  /// Built eagerly: unlike the engine it needs nothing resolved first, and
  /// the launch-time check should not queue behind helper discovery.
  @State private var updates = UpdateModel.live()

  /// Read once. Nothing in it can change while the app runs — it is all
  /// stamped into the bundle at build time — and both the menu item and the
  /// window title need the name.
  private let about = AboutInfo.main

  var body: some Scene {
    // `Window`, not `WindowGroup`. The engine is built once at launch
    // (design §2) and the app is single-window (design §4), and a
    // `WindowGroup` enforces neither: ⌘N stays live, and each new window
    // gets its own `@State`.
    //
    // That second `@State` used to be the whole danger. A second window ran
    // `setUp()` again and built a second `QueueController` — a second
    // `QueueEngine` over the same queue.json and the same workspace — and
    // `QueueEngine.start()` sweeps that workspace unconditionally, so
    // opening a window would delete the working files of a download already
    // in flight while the first engine's pending save never flushed. That
    // particular disaster is now prevented twice: `setUp()` awaits
    // `QueueHost.shared`, which resolves once and hands every later caller
    // the same controller, so a second window would share the engine rather
    // than construct one. `Window` is no longer the only thing standing
    // between the app and two engines — but nothing else here changed: ⌘N
    // would still be live, each window would still carry its own `@State`,
    // and single-instance is still the guarantee this app wants.
    //
    // Removing the New Window command from the group would hide the menu
    // item while leaving the scene duplicable by anything else that opens
    // one. `Window` makes single-instance the scene's own guarantee, and
    // drops the menu item as a consequence rather than as the fix.
    Window("Oxbow", id: Self.queueWindowID) {
      Group {
        // One view for both outcomes. `QueueView` owns the toolbar and the
        // banner, so a payload-missing launch gets the `+`-disabled window
        // design §6 describes rather than a bare page with no chrome.
        if let content {
          QueueView(content: content, updates: updates)
        } else {
          ProgressView().frame(minWidth: 480, minHeight: 320)
        }
      }
      .task { await setUp() }
      // Screenshot framing only. Has to be AppKit rather than `.defaultSize`
      // below, which frame restoration overrides — see `ScreenshotFixture`.
      #if DEBUG
      .background {
        ScreenshotWindowSizer()
        ScreenshotIntakeOpener(
          windowID: Self.intakeWindowID,
          infoWindowID: Self.infoWindowID)
      }
      #endif
      // Its own task, not a step inside `setUp()`: the two are unrelated,
      // and a check that waits for the helper to be found would be a check
      // that never runs on the builds most in need of an update.
      //
      // Guarded, because `OxbowTests` is hosted by this app: without it every
      // `xcodebuild test` made a live GitHub request and wrote the real
      // preferences. See `AppComposition.isUserSession`.
      .task {
        guard AppComposition.isUserSession else { return }
        await updates.checkAutomatically()
      }
    }
    .defaultSize(width: 720, height: 480)
    .windowResizability(.contentMinSize)
    .commands {
      // Replace, not add. The stock item calls
      // `orderFrontStandardAboutPanel`, whose one small credits scroller has
      // no room for the licence text this app is obliged to make reachable
      // (see `AboutView`). Leaving it in place would put two About items in
      // the menu, one of them insufficient.
      CommandGroup(replacing: .appInfo) {
        AboutCommand(applicationName: about.applicationName)
        // Where a Mac app puts it, and the only way to get a definitive
        // answer: the automatic check is silent unless it finds something,
        // so without this there is no way to tell "up to date" from "broken".
        CheckForUpdatesCommand(updates: updates)
      }
      // ⌘N is free: the queue is a `Window`, so there is no New Window item to
      // collide with. It opens intake, which is the only thing in this app a
      // person creates. The toolbar `+` in `QueueView` opens the same window —
      // the shortcut is a second path to it, never the only one.
      CommandGroup(replacing: .newItem) {
        AddDownloadCommand(isEnabled: controller != nil)
      }
      // Its own top-level menu, the way Transmission gives transfers one.
      // Everything here is also reachable by right-clicking a row; the menu is
      // what makes it discoverable, and what gives it key equivalents.
      DownloadsCommands()
    }

    // Intake as its own window, not a sheet on the queue.
    //
    // A sheet cannot exceed its host window, and this form legitimately wants
    // most of a screen once the render options are open — which made the queue
    // window's minimum size a function of its own modal. A window sizes itself,
    // remembers what the user dragged it to, and closes with ⌘W.
    //
    // `Window`, so ⌘N and the `+` re-focus the one that exists rather than
    // stacking half-filled copies of a form that each hold their own
    // `IntakeModel` and their own in-flight metadata fetch.
    Window("Add Download", id: Self.intakeWindowID) {
      // Unreachable without a controller — both the menu item and the toolbar
      // button are disabled in that case — but the window needs one, and there
      // is no honest thing to put here instead.
      if let controller {
        IntakeWindow(controller: controller)
      }
    }
    .defaultSize(width: 560, height: 680)
    .windowResizability(.contentMinSize)
    .defaultPosition(.center)
    // Not restored on launch. macOS reopens whatever windows were open at
    // quit, which for a half-filled form means every launch starts with an
    // Add Download window nobody asked for — and its `IntakeModel` is
    // rebuilt empty anyway, so what reappears is a blank form, not the one
    // that was there.
    .restorationBehavior(.disabled)

    // Get Info, one window per download.
    //
    // `WindowGroup(for:)` rather than a single inspector window: asking for
    // info on the same job twice focuses the window that is already open
    // instead of stacking duplicates, and two downloads can be compared side
    // by side — which is what Finder's ⌘I does and what a single
    // follows-the-selection panel cannot.
    WindowGroup(id: Self.infoWindowID, for: JobID.self) { $jobID in
      if let jobID, let controller {
        JobInfoWindow(jobID: jobID, controller: controller)
      }
    }
    .defaultSize(width: 460, height: 620)
    .windowResizability(.contentMinSize)
    // Same reasoning as intake: macOS reopens what was open at quit, and a
    // restored info window would be pointing at a job whose queue has since
    // been reconciled — or removed entirely.
    .restorationBehavior(.disabled)

    // `Window`, so the About box is single-instance for the same reason the
    // queue and intake are: choosing the menu item twice brings the existing
    // one forward instead of stacking copies.
    //
    // `commandsRemoved()` drops the menu commands this scene would otherwise
    // contribute. The About box should be reachable only from the menu item,
    // the way a Mac About box is.
    Window("About \(about.applicationName)", id: Self.aboutWindowID) {
      AboutView(info: about)
    }
    .windowResizability(.contentSize)
    .commandsRemoved()
    .defaultPosition(.center)
    // Nothing here is worth restoring, and an About box reappearing on launch
    // is the same unasked-for window intake would be.
    .restorationBehavior(.disabled)

    // ⌘, and the app-menu item, for free — this is the whole scene.
    // `SettingsView` reads and writes `Preferences()`'s default `.standard`
    // domain itself; nothing here needs to be threaded through.
    //
    // macOS 26 auto-icons *system-provided* menu items (design doc §7.1):
    // `About Oxbow` and `Check for Updates…` above both needed an explicit
    // `Label` because they are ours, not the system's, and drew bare without
    // one. `Settings…` is a scene macOS itself generates the menu item for,
    // the same way it generates `Quit` and `Hide` — so it may already be
    // auto-iconed, unlike those two. **Unverified**: this cannot be checked
    // without opening the built app's menu bar, which this change does not
    // do. If it turns out to draw bare, replace this scene's content with
    // `CommandGroup(replacing: .appSettings) { ... Label("Settings…",
    // systemImage: "gearshape") ... }`, the same shape as the `CommandGroup`
    // above, plus an `@Environment(\.openSettings)` action.
    Settings {
      SettingsView()
    }
  }

  /// The id the About menu item opens.
  static let aboutWindowID = "about"

  /// The queue itself — the window the update banner appears in.
  static let queueWindowID = "queue"

  /// The id `QueueView` and the Downloads menu open Get Info with.
  static let infoWindowID = "info"

  /// The id both the menu item and `QueueView`'s toolbar button open.
  static let intakeWindowID = "intake"

  private var controller: QueueController? {
    if case .ready(let controller) = content { return controller }
    return nil
  }

  private func setUp() async {
    guard content == nil else { return }
    content = await QueueHost.shared.ready()
  }
}

/// The File ▸ Add Download… item.
///
/// A `View` rather than a `Button` written inline in the `CommandGroup`,
/// because `openWindow` is an environment value and an `App` has no
/// environment to read it from. Command content is a view builder, so a view
/// placed there does have one — this is the supported way for a menu item to
/// open a scene.
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

/// The Oxbow ▸ Check for Updates… item.
///
/// Opens the queue window before checking, because the queue window is where
/// the answer is drawn. Choosing this from the menu bar with every window
/// closed would otherwise run a check whose result nothing displays.
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

/// The Oxbow ▸ About Oxbow item.
///
/// A `View` for the same reason `AddDownloadCommand` is one: `openWindow` is
/// an environment value, and an `App` has no environment to read it from.
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

/// Delays app termination until the running helpers have been killed and the
/// queue's pending debounced save is on disk.
///
/// `QueueController.shutDown()` is async; `applicationWillTerminate(_:)` is
/// not, and by the time it runs the app is already committed to quitting, so
/// there is nothing left to await it against. `applicationShouldTerminate(_:)`
/// is the hook that is allowed to say "not yet": returning `.terminateLater`
/// suspends the quit, and `NSApp.reply(toApplicationShouldTerminate:)` resumes
/// it once the shutdown actually completes. This blocks no thread — the work
/// runs to completion on `QueueEngine`'s own actor, and the reply is sent only
/// after that `await` returns, which is what guarantees both the kills and the
/// write land before the process is allowed to exit.
///
/// **Both halves have to happen here, and in that order.** Quitting mid-
/// download used to leave `TwitchDownloaderCLI` and its FFmpeg running as
/// orphans, because `HelperProcessing.cancel()` is the only thing that signals
/// their process group and nothing on the quit path called it. The delay this
/// adds is bounded by one ~2s SIGTERM grace period however many steps are in
/// flight, because `shutDown()` signals them concurrently — and the scheduler
/// admits at most one `.network` and one `.compute` step, so it is never more
/// than two.
///
/// Verified directly, not assumed, against a real VOD download in the built
/// app: quit while both `TwitchDownloaderCLI` and the `ffmpeg` it had spawned
/// were running, then `pgrep`'d for each from outside. Before this change the
/// app exited in ~0.3s and both survived, reparented to `launchd` with their
/// cwd still inside the job workspace that the next launch's
/// `Workspace.removeAll()` sweep deletes. After it, the app takes ~2.4s to go
/// — one SIGTERM grace period, externally observable proof that
/// `.terminateLater` really does hold the process open for the awaited work —
/// and `pgrep` finds neither. Relaunching then showed the step reconciled to
/// `.failed(.interrupted)`, as designed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Touches the notifier's owner so it registers as the notification
  /// centre's delegate as early as the app can manage — a response arriving
  /// before the delegate exists is a response that goes nowhere.
  ///
  /// Fire-and-forget: `applicationDidFinishLaunching` cannot await, and
  /// nothing here needs the result. `ready()` is idempotent, so the scene's
  /// own `.task` joins this resolution rather than starting a second one.
  func applicationDidFinishLaunching(_ notification: Notification) {
    Task { _ = await QueueHost.shared.ready() }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // `resolvedController`, not `ready()`: quitting must never *start* a
    // resolution in order to discover there is nothing to shut down.
    guard let controller = QueueHost.shared.resolvedController else { return .terminateNow }
    Task {
      await controller.shutDown()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
