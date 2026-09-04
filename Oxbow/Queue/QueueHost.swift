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

  /// The engine from the moment it is **constructed**, which is deliberately
  /// earlier than `ready()` hands it out.
  ///
  /// **Two ways to reach one object, and they are not interchangeable.**
  /// `ready()` answers only once `start()` has loaded the saved queue and
  /// swept the workspace, because anything that *enqueues* must never see a
  /// pre-start engine: `start()` does both unconditionally, so a job added
  /// before it is either overwritten by the load or has its workspace deleted
  /// by the sweep. Quitting wants the opposite. It needs whatever exists right
  /// now — and a `nil` here for however long `start()` takes is
  /// `applicationShouldTerminate` returning `.terminateNow` and skipping
  /// `shutDown()`, which is precisely the window in which
  /// `TwitchDownloaderCLI` and its FFmpeg survive the quit as orphans (see
  /// `AppDelegate`'s comment, hand-verified against a real download).
  ///
  /// So: `ready()` for every caller that will *use* the engine, this one for
  /// the single caller that only wants to stop it.
  private var liveController: QueueController?

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

  /// The controller if one has been built, for `applicationShouldTerminate`,
  /// which must not itself start a resolution just to find nothing to shut
  /// down.
  ///
  /// Reads `liveController` rather than `state`, so a quit arriving during
  /// `start()` still finds the engine to shut down. See that property for why
  /// the two answers deliberately differ in that span.
  var resolvedController: QueueController? { liveController }

  /// Builds the notifier, and with it registers the notification centre's
  /// delegate and the `finished` category's "Show in Finder" action.
  ///
  /// **Synchronous, and separate from `ready()`, for two reasons.**
  /// `UNUserNotificationCenter` wants its delegate set before the app finishes
  /// launching, so that a notification response which *cold-launches* the app
  /// is delivered rather than dropped — and `applicationDidFinishLaunching`
  /// cannot await, so the `Task` that nudges `ready()` cannot even begin until
  /// after it returns. And resolution is not a reliable route to the notifier
  /// anyway: `attachStatusObservers` is only reached on the `.ready` branch,
  /// so a `helperMissing` launch would build no notifier at all and leave the
  /// centre with no delegate for the whole session.
  ///
  /// `lazy` is what makes this safe to call alongside `attachStatusObservers`:
  /// whichever gets there first constructs the one notifier and the other
  /// finds it. Still `nil` under `xcodebuild test` — see `notifier`.
  func registerNotificationDelegate() {
    _ = notifier
  }

  /// Tells the user what an App Intent just did.
  ///
  /// Narrow on purpose: `notifier` stays private, so nothing else in the app
  /// can reach for it and start posting banners of its own. Inert under
  /// `xcodebuild test`, where `AppComposition.isUserSession` is false and the
  /// notifier is nil.
  func notifyIntentOutcome(_ outcome: IntentSubmission.Outcome) {
    notifier?.announceIntentSubmission(
      title: outcome.notificationTitle,
      body: outcome.notificationBody)
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
          guard case .resolved(let content) = state else {
            // Unreachable, and crashing is the point. The only states are
            // `.idle`, `.resolving` and `.resolved`; the `switch` above saw
            // `.resolving` in this same main-actor turn with no suspension
            // between there and here; and nothing ever moves the state
            // backwards. Reaching this line means that graph gained an edge,
            // and there is no honest answer to resume with — so a debug crash
            // that names the broken invariant beats returning silently and
            // hanging this caller forever.
            preconditionFailure(
              "QueueHost left .resolving without settling on .resolved; a caller would hang")
          }
          continuation.resume(returning: content)
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
      // Redundant on the real path, where `resolveFromBundleInternal` set it
      // before `start()`. Here so the injected `resolve` seam cannot make
      // `resolvedController` disagree with the outcome it just published.
      if case .ready(let controller) = content { liveController = controller }
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
        // Reachable through `resolvedController` from here, so a quit during
        // `start()` still has something to shut down — and *not* through
        // `ready()`, which waits for `start()` so no enqueuer ever sees a
        // pre-start engine. See `liveController`.
        liveController = controller
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
