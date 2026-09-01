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

  /// The completion chime, in `Contents/Resources`.
  ///
  /// **Not the `.mp3` it arrived as.** `UNNotificationSound` reads `aiff`,
  /// `wav` and `caf` only, and fails by falling back to the default sound
  /// rather than by complaining — so a wrong extension here is a bug that
  /// sounds like a working feature. Converted with `afconvert` and trimmed
  /// first: the original carried 2.96s of trailing silence after 1.07s of
  /// audio, which a notification would have held open for no reason.
  nonisolated private static let dingFile = "ding.caf"

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
        content.sound = UNNotificationSound(named: UNNotificationSoundName(Self.dingFile))
      case .failed:
        content.title = "Download failed"
        // The system sound, not the chime. The chime says "your file is
        // ready"; playing it for a failure would be the app congratulating
        // itself on the thing that went wrong.
        content.sound = .default
      }
      content.body = event.title

      center.add(UNNotificationRequest(
        identifier: event.job.rawValue.uuidString,
        content: content,
        trigger: nil))
    }

    baseline = NotificationDecision.statuses(of: jobs)
  }

  // MARK: - UNUserNotificationCenterDelegate

  /// **The chime always plays; the banner is suppressed while Oxbow is
  /// frontmost.**
  ///
  /// The two are separate decisions and were first written as one. A banner
  /// over the window that already shows the finished row adds nothing — that
  /// much is the platform's own default. But the sound is what carries when
  /// your attention is elsewhere on screen, or when you are not at the desk at
  /// all, and suppressing it alongside the banner made this app's one audible
  /// signal silent in the case where the window happened to be in front.
  ///
  /// Focus and Do Not Disturb still silence it, which is correct and is not
  /// something to work around: an eighty-eight minute composite finishing is
  /// not an emergency.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification) async -> UNNotificationPresentationOptions
  {
    await MainActor.run { NSApp.isActive ? [.sound] : [.banner, .sound] }
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
