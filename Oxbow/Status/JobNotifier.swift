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
  nonisolated private static let dingFile = "ding"

  /// **The chime is played by us, not by `UNNotificationSound`.**
  ///
  /// Setting `content.sound` produced no audio on macOS 26.6.2 — not with the
  /// bundled file and not with `.default` either, while `authorizationStatus`
  /// read `.authorized`, `soundSetting` read `.enabled`, alert volume was 99,
  /// and `center.add` reported success. Four probe notifications covering
  /// default, our file by two names, and no sound at all were silent alike.
  /// The same file through `NSSound` in the same process plays, so the app can
  /// reach the speakers; only the notification-sound path cannot.
  ///
  /// Why that path is silent is unresolved and may be specific to this
  /// machine. What is certain is that a feature which depends on it does not
  /// work here, and one that does not is available — so this plays the sound
  /// directly and asks the system for none, which also means the two can never
  /// double up if that path starts working.
  private lazy var chime: NSSound? = Bundle.main
    .url(forResource: Self.dingFile, withExtension: "caf")
    .flatMap { NSSound(contentsOf: $0, byReference: false) }

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
      // `content.sound` is deliberately left nil throughout: the chime is
      // played here instead, by us. See `chime` and `playChimeIfAllowed()`.
      if event.outcome == .finished { playChimeIfAllowed() }

      center.add(UNNotificationRequest(
        identifier: event.job.rawValue.uuidString,
        content: content,
        trigger: nil))
    }

    baseline = NotificationDecision.statuses(of: jobs)
  }

  // MARK: - UNUserNotificationCenterDelegate

  /// The banner is suppressed while Oxbow is frontmost — over the window that
  /// already shows the finished row it would only repeat it.
  ///
  /// **This method decides the banner and nothing else.** It is called only
  /// while the app is frontmost, so it cannot be where the chime lives; see
  /// `playChimeIfAllowed()`.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification) async -> UNNotificationPresentationOptions
  {
    // Banner only. The chime is played when the notification is posted — see
    // `playChimeIfAllowed()` for why it cannot live here. No `.sound` is
    // requested, so the two can never double up.
    return await MainActor.run { NSApp.isActive ? [] : [.banner] }
  }

  /// Plays the chime, if the user has not turned sound off for Oxbow.
  ///
  /// **Called where the notification is posted, not from `willPresent`.**
  /// `willPresent` runs only while the app is frontmost — when Oxbow is in the
  /// background the system presents the banner without consulting the
  /// delegate, so a chime played from there is silent in precisely the case
  /// the chime exists for. That was the first implementation and it never
  /// made a sound.
  ///
  /// **The cost of owning the sound: Focus and Do Not Disturb no longer
  /// silence it.** When `content.sound` carries the audio, the system honours
  /// those for us; playing it ourselves puts us outside that. The per-app
  /// sound preference is checked here because it can be, but there is no
  /// public API for Focus state, so under Focus the banner is suppressed and
  /// the chime is not.
  ///
  /// That is a real regression against the platform path and it is accepted
  /// only because the platform path produced no audio at all (see `chime`). If
  /// `UNNotificationSound` is ever found to work, this should go back to it —
  /// a sound the user's Focus mode cannot stop is worse behaved than one that
  /// is occasionally missed.
  private func playChimeIfAllowed() {
    guard let center else { return }
    Task { [weak self] in
      let allowed = await center.notificationSettings().soundSetting == .enabled
      guard allowed else { return }
      await MainActor.run {
        self?.playChime()
      }
    }
  }

  private func playChime() {
    guard let chime else { return }
    if chime.isPlaying { chime.stop() }
    chime.play()
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
