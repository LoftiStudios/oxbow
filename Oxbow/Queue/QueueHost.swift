import AppKit
import Foundation
import OxbowKit

/// Single engine shared by windows and background intents. The first ready() caller resolves
/// it; concurrent callers await the same result without depending on window or app-delegate
/// ordering.
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

  /// Expose a constructed controller to shutdown immediately, but ready() must wait for start()
  /// to finish loading and sweeping before any caller can enqueue.
  private var liveController: QueueController?

  /// Submission recording shares the resolved support directory. Nil during hosted tests to
  /// prevent writes to the user's video record.
  private(set) var videoRecording: VideoRecording?

  /// Initialize on first use, independent of launch ordering. Disable live status surfaces
  /// during hosted tests.
  private lazy var dock: DockPresenter? =
    AppComposition.isUserSession ? DockPresenter() : nil
  private lazy var notifier: JobNotifier? =
    AppComposition.isUserSession ? JobNotifier() : nil

  init(resolve: (() async -> QueueContent)? = nil) {
    self.resolve = resolve
  }

  /// Read the constructed controller without initiating resolution, including while startup is
  /// in progress.
  var resolvedController: QueueController? { liveController }

  /// Register the notification delegate synchronously before launch completes, even if engine
  /// resolution fails. Lazy construction shares the same notifier with status observers; tests
  /// keep it nil.
  func registerNotificationDelegate() {
    _ = notifier
  }

  /// Post intent outcomes through the private notifier; inert during hosted tests.
  func notifyIntentOutcome(_ outcome: IntentSubmission.Outcome) {
    notifier?.announceIntentSubmission(
      title: outcome.notificationTitle,
      body: outcome.notificationBody)
  }

  /// Use the shared notifier for findings. A second notifier would replace the notification
  /// delegate and lose existing action handling.
  func notifyFindings(title: String, body: String) {
    notifier?.announceFindings(title: title, body: body)
  }

  /// Resolves the engine, or returns why it could not. Safe to call from
  /// anywhere, any number of times, concurrently.
  func ready() async -> QueueContent {
    switch state {
    case .resolved(let content):
      return content

    case .resolving:
      return await withCheckedContinuation { continuation in
        guard case .resolving(var waiting) = state else {
          // If resolution has completed, return its result instead of adding a waiter that will
          // never resume.
          guard case .resolved(let content) = state else {
            // State cannot return to idle here. Fail rather than strand this continuation if
            // that invariant breaks.
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
      // Capture waiters before publishing resolved state, then resume them.
      let waiting: [CheckedContinuation<QueueContent, Never>]
      if case .resolving(let pending) = state { waiting = pending } else { waiting = [] }
      state = .resolved(content)
      // Keep resolvedController consistent for injected resolvers as well as live startup.
      if case .ready(let controller) = content { liveController = controller }
      for continuation in waiting { continuation.resume(returning: content) }
      return content
    }
  }

  /// Attach status observers before start() so NotificationDecision seeds silently from the
  /// first reconciled snapshot.
  private func resolveFromBundleInternal() async -> QueueContent {
    let executable = Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
    do {
      let support = try AppComposition.defaultSupportDirectory()
      switch AppComposition.resolve(bundleExecutable: executable, supportDirectory: support) {
      case .ready(let configuration):
        let controller = QueueController(configuration: configuration)
        // Expose the controller for shutdown during start(); ready() still waits for startup
        // completion.
        liveController = controller
        if AppComposition.isUserSession {
          videoRecording = VideoRecording.live(supportDirectory: support)
        }
        attachStatusObservers(to: controller, supportDirectory: support)
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

  /// Fan out one snapshot subscription to Dock, notifier, and AutoDownloadObserver before
  /// startup. Explicitly gate user sessions: AutoDownloadObserver writes user data, so safety
  /// must not depend on whether other observers happen to be nil.
  private func attachStatusObservers(to controller: QueueController, supportDirectory: URL) {
    guard AppComposition.isUserSession else { return }
    guard let dock, let notifier else { return }
    // Attach the store after support-directory resolution; the notifier may already exist for
    // cold-launch response handling.
    notifier.videoRecordStore = VideoRecordStore(
      fileURL: AppComposition.videoRecordURL(supportDirectory: supportDirectory))
    let autoDownloadObserver = AutoDownloadObserver(
      store: WatchStore(fileURL: AppComposition.watchStoreURL(supportDirectory: supportDirectory)))
    controller.onSnapshot = { jobs in
      dock.apply(jobs)
      notifier.apply(jobs)
      autoDownloadObserver.apply(jobs)
    }
    controller.onEnqueue = { notifier.requestAuthorizationIfNeeded() }
  }
}
