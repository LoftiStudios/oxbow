import AppKit
import SwiftUI
import OxbowKit

@main
struct OxbowApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var content: QueueContent?

  var body: some Scene {
    // `Window`, not `WindowGroup`. The engine is built once at launch
    // (design §2) and the app is single-window (design §4), and a
    // `WindowGroup` enforces neither: ⌘N stays live, and each new window
    // gets its own `@State`, so a second window builds a second
    // `QueueController` — a second `QueueEngine` over the same queue.json
    // and the same workspace. `QueueEngine.start()` sweeps that workspace
    // unconditionally, so opening a window would delete the working files of
    // a download already in flight, and `appDelegate.controller` would be
    // clobbered so the first engine's pending save never flushed.
    //
    // Removing the New Window command from the group would hide the menu
    // item while leaving the scene duplicable by anything else that opens
    // one. `Window` makes single-instance the scene's own guarantee, and
    // drops the menu item as a consequence rather than as the fix.
    Window("Oxbow", id: "queue") {
      Group {
        // One view for both outcomes. `QueueView` owns the toolbar and the
        // banner, so a payload-missing launch gets the `+`-disabled window
        // design §6 describes rather than a bare page with no chrome.
        if let content {
          QueueView(content: content)
        } else {
          ProgressView().frame(minWidth: 480, minHeight: 320)
        }
      }
      .task { await setUp() }
    }
    .windowResizability(.contentMinSize)
  }

  private func setUp() async {
    guard content == nil else { return }

    let executable = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
    do {
      let support = try AppComposition.defaultSupportDirectory()
      switch AppComposition.resolve(bundleExecutable: executable, supportDirectory: support) {
      case .ready(let configuration):
        let controller = QueueController(configuration: configuration)
        content = .ready(controller)
        appDelegate.controller = controller
        await controller.start()
      case .helperMissing(let message):
        content = .unavailable(message)
      }
    } catch {
      content = .unavailable(
        "Oxbow could not prepare its support directory: \(error.localizedDescription)")
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
  var controller: QueueController?

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let controller else { return .terminateNow }
    Task {
      await controller.shutDown()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
