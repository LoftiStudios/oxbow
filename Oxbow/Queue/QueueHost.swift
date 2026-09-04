import AppKit
import Foundation
import OxbowKit

/// The one engine, and the only way to wait for it.
///
/// **Why this exists.** `setUp()` used to run from the queue scene's `.task`,
/// which made building the engine a side effect of a *window appearing*. An
/// App Intent runs with the app not launched, and deliberately shows no
/// window (docs/design/automation.md §6) — so under the old arrangement it
/// would have waited for a controller that nothing was constructing. Not
/// slow: permanently hung.
///
/// **This removes an ordering assumption rather than moving it**, which is
/// the same correction `AppDelegate`'s `lazy` dock and notifier already
/// record. Those were built in `applicationDidFinishLaunching` on the
/// assumption that it precedes the scene's `.task`; it does not, and the fix
/// was to stop depending on which came first. Whichever caller reaches
/// `ready()` first does the work here, and every other caller awaits that
/// same outcome. Nothing needs to know the order.
///
/// **A singleton, deliberately.** The app is single-engine by construction —
/// see the `Window` comment in `OxbowApp` for what a second `QueueEngine`
/// over the same `queue.json` and workspace destroys. A shared instance that
/// *matches* an invariant the app already enforces is honest. The alternative
/// is threading a controller into a type App Intents constructs for us, which
/// cannot be done.
@MainActor
final class QueueHost {
  static let shared = QueueHost()

  private enum State {
    case idle
    /// Resolution is in flight; these are the callers waiting on it.
    case resolving([CheckedContinuation<QueueContent, Never>])
    case resolved(QueueContent)
  }

  private var state: State = .idle
  private let resolve: (() async -> QueueContent)?

  /// **`lazy`, and for the reason `AppDelegate`'s were.** Built on first use
  /// by whichever caller gets there, so neither depends on when it is first
  /// reached. Both stay `nil` under `xcodebuild test`: `OxbowTests` is hosted
  /// by this app, and a permission prompt during a test run is a modal that
  /// hangs CI.
  private lazy var dock: DockPresenter? =
    AppComposition.isUserSession ? DockPresenter() : nil
  private lazy var notifier: JobNotifier? =
    AppComposition.isUserSession ? JobNotifier() : nil

  init(resolve: (() async -> QueueContent)? = nil) {
    self.resolve = resolve
  }

  /// The controller if one resolved, for `applicationShouldTerminate`, which
  /// must not itself start a resolution just to find nothing to shut down.
  var resolvedController: QueueController? {
    guard case .resolved(.ready(let controller)) = state else { return nil }
    return controller
  }

  /// Resolves the engine, or returns why it could not. Safe to call from
  /// anywhere, any number of times, concurrently.
  func ready() async -> QueueContent {
    switch state {
    case .resolved(let content):
      return content

    case .resolving:
      return await withCheckedContinuation { continuation in
        // Re-read: `state` cannot have changed between the switch and here
        // (both are on the main actor with no suspension between them), but
        // reading it again is what makes appending to the right array a
        // fact rather than an assumption.
        guard case .resolving(var waiting) = state else {
          // Resolution finished while this caller was suspending. Answer
          // from the settled state rather than joining a queue nobody will
          // ever drain.
          if case .resolved(let content) = state { continuation.resume(returning: content) }
          return
        }
        waiting.append(continuation)
        state = .resolving(waiting)
      }

    case .idle:
      state = .resolving([])
      let content: QueueContent
      if let resolve {
        content = await resolve()
      } else {
        content = await resolveFromBundleInternal()
      }
      // Take the waiters before publishing, so a continuation resumed below
      // cannot observe `.resolving` and enqueue itself into an array that is
      // about to be discarded.
      let waiting: [CheckedContinuation<QueueContent, Never>]
      if case .resolving(let pending) = state { waiting = pending } else { waiting = [] }
      state = .resolved(content)
      for continuation in waiting { continuation.resume(returning: content) }
      return content
    }
  }

  /// What `OxbowApp.setUp()` used to do inline.
  ///
  /// The status observers are attached **before** `start()`, so they see the
  /// first reconciled snapshot and seed from it rather than missing it —
  /// `NotificationDecision` relies on that first snapshot to establish a
  /// baseline silently (docs/design/status.md §7.2).
  private func resolveFromBundleInternal() async -> QueueContent {
    let executable = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
    do {
      let support = try AppComposition.defaultSupportDirectory()
      switch AppComposition.resolve(bundleExecutable: executable, supportDirectory: support) {
      case .ready(let configuration):
        let controller = QueueController(configuration: configuration)
        attachStatusObservers(to: controller)
        await controller.start()
        return .ready(controller)
      case .helperMissing(let message):
        return .unavailable(message)
      }
    } catch {
      return .unavailable(
        "Oxbow could not prepare its support directory: \(error.localizedDescription)")
    }
  }

  /// Wires the status surfaces to the queue. Moved here from `AppDelegate`
  /// because it must happen before `start()` regardless of which caller
  /// triggered resolution, and only this type knows when that is.
  private func attachStatusObservers(to controller: QueueController) {
    // Nil only under `xcodebuild test`, where both are deliberately absent.
    guard let dock, let notifier else { return }
    controller.onSnapshot = { jobs in
      dock.apply(jobs)
      notifier.apply(jobs)
    }
    controller.onEnqueue = { notifier.requestAuthorizationIfNeeded() }
  }
}
