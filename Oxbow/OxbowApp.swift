import AppKit
import SwiftUI
import OxbowKit

@main
struct OxbowApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var controller: QueueController?
  @State private var unavailable: String?

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
        if let controller {
          QueueView(controller: controller, unavailable: unavailable)
        } else if let unavailable {
          ContentUnavailableView {
            Label("Downloads unavailable", systemImage: "exclamationmark.triangle")
          } description: {
            Text(unavailable)
          }
          .frame(minWidth: 480, minHeight: 320)
        } else {
          ProgressView().frame(minWidth: 480, minHeight: 320)
        }
      }
      .task { await setUp() }
    }
    .windowResizability(.contentMinSize)
  }

  private func setUp() async {
    guard controller == nil, unavailable == nil else { return }

    let executable = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
    do {
      let support = try AppComposition.defaultSupportDirectory()
      switch AppComposition.resolve(bundleExecutable: executable, supportDirectory: support) {
      case .ready(let configuration):
        let controller = QueueController(configuration: configuration)
        self.controller = controller
        appDelegate.controller = controller
        await controller.start()
      case .helperMissing(let message):
        unavailable = message
      }
    } catch {
      unavailable = "Oxbow could not prepare its support directory: \(error.localizedDescription)"
    }
  }
}

/// Delays app termination until the queue's pending debounced save is
/// flushed to disk.
///
/// `QueueEngine.flush()` is async; `applicationWillTerminate(_:)` is not, and
/// by the time it runs the app is already committed to quitting, so there is
/// nothing left to await it against. `applicationShouldTerminate(_:)` is the
/// hook that is allowed to say "not yet": returning `.terminateLater`
/// suspends the quit, and `NSApp.reply(toApplicationShouldTerminate:)`
/// resumes it once the flush actually completes. This blocks no thread —
/// `flush()` runs to completion on `QueueEngine`'s own actor, and the reply
/// is sent only after that `await` returns, which is what guarantees the
/// write lands before the process is allowed to exit.
///
/// Verified directly, not assumed: launched the built app from a terminal
/// (so its process could be tracked), sent it the standard Quit Apple Event,
/// and confirmed from outside the process that the app stayed alive for the
/// full duration of an artificial delay inserted before `flush()` — it did
/// not exit early. `queue.json`'s mtime landed at the exact moment the
/// awaited flush completed (matching a log line written right after
/// `flush()` returned), and the process only exited after that. This
/// confirms `applicationShouldTerminate(_:)` genuinely fires on quit, that
/// `.terminateLater` genuinely holds the process open, and that the write
/// completes before exit rather than racing it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var controller: QueueController?

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let controller else { return .terminateNow }
    Task {
      await controller.flush()
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
