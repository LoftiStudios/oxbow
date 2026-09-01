import AppKit
import OxbowKit
import UserNotifications

/// Tells the user when a job settles, and reveals what it delivered.
///
/// The delivered files travel in the notification's `userInfo`, so the reveal
/// action needs no access to queue state — which by the time someone clicks
/// may have moved on, or may have had the job removed out from under it.
@MainActor
final class JobNotifier: NSObject, UNUserNotificationCenterDelegate {

  // `nonisolated`: the class is `@MainActor`, which would otherwise isolate
  // these to it, and `filesKey` is read from the nonisolated delegate method
  // that handles a notification response.
  nonisolated private static let revealAction = "studio.lofti.Oxbow.reveal"
  nonisolated private static let finishedCategory = "studio.lofti.Oxbow.finished"
  nonisolated private static let filesKey = "files"

  private var baseline: [JobID: JobStatus] = [:]
  private var hasRequestedAuthorization = false

  /// `nil` under `xcodebuild test`.
  ///
  /// `OxbowTests` is hosted by this app, so a test run launches it for real.
  /// An authorization prompt during CI is a modal that hangs the run —
  /// strictly worse than the live GitHub requests that put
  /// `AppComposition.isUserSession` there in the first place. Holding the
  /// centre optionally, rather than gating each call site, means a future
  /// method cannot forget the check.
  private let center: UNUserNotificationCenter?

  override init() {
    center = AppComposition.isUserSession ? .current() : nil
    super.init()

    guard let center else { return }
    center.delegate = self
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: Self.finishedCategory,
        actions: [UNNotificationAction(
          identifier: Self.revealAction,
          title: "Show in Finder",
          options: [.foreground])],
        intentIdentifiers: [])])
  }

  /// Asked once, on the first enqueue.
  ///
  /// Not at first launch: the user has no idea yet what the app does, and a
  /// permission prompt is the worst possible first impression of a tool they
  /// have not used. Not at first completion either — that is the event we
  /// would be asking permission to report, and it is already over. On first
  /// enqueue the context answers the question by itself.
  func requestAuthorizationIfNeeded() {
    guard let center, !hasRequestedAuthorization else { return }
    hasRequestedAuthorization = true
    // Silent on denial, like the update check: a user who says no gets an app
    // that behaves exactly as it did before this feature existed.
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  func apply(_ jobs: [Job]) {
    guard let center else { return }

    // A job absent from `baseline` never fires, which is what makes the first
    // snapshot seed silently — see `NotificationDecision.events(from:to:)`.
    for event in NotificationDecision.events(from: baseline, to: jobs) {
      let content = UNMutableNotificationContent()
      switch event.outcome {
      case .finished:
        content.title = "Download finished"
        content.categoryIdentifier = Self.finishedCategory
        content.userInfo = [Self.filesKey: event.files.map(\.path)]
      case .failed:
        content.title = "Download failed"
      }
      content.body = event.title
      content.sound = .default

      center.add(UNNotificationRequest(
        identifier: event.job.rawValue.uuidString,
        content: content,
        trigger: nil))
    }

    baseline = NotificationDecision.statuses(of: jobs)
  }

  // MARK: - UNUserNotificationCenterDelegate

  /// Suppressed while Oxbow is frontmost — the queue row already said it.
  /// This is the platform default, spelled out because the delegate has to
  /// exist for the reveal action anyway.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification) async -> UNNotificationPresentationOptions
  {
    await MainActor.run { NSApp.isActive ? [] : [.banner, .sound] }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse) async
  {
    let paths = response.notification.request.content
      .userInfo[JobNotifier.filesKey] as? [String] ?? []

    await MainActor.run {
      guard !paths.isEmpty else {
        NSApp.activate(ignoringOtherApps: true)
        return
      }
      NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(filePath: $0) })
    }
  }
}
