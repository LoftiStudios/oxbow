import AppKit
import OxbowKit
import UserNotifications

/// Notify on settled jobs. Store delivered URLs in userInfo so reveal survives queue changes or
/// removal.
@MainActor
final class JobNotifier: NSObject, UNUserNotificationCenterDelegate {

  // Delegate callbacks read these constants outside the main actor.
  nonisolated private static let revealAction = "studio.lofti.Oxbow.reveal"
  nonisolated private static let finishedCategory = "studio.lofti.Oxbow.finished"
  nonisolated private static let filesKey = "files"

  /// Default-click routing flag; findings need no separate action category.
  nonisolated private static let revealWatchingKey = "revealWatching"

  /// Bundled completion chime. Notification audio accepts AIFF, WAV, or CAF, not MP3.
  nonisolated private static let dingFile = "ding"

  /// Use NSSound because both custom and default UNNotificationSound were silent in testing on
  /// macOS 26.6.2. Cause unresolved and possibly machine-specific. Leave content.sound nil to
  /// prevent duplicate playback if that path recovers.
  private lazy var chime: NSSound? = Bundle.main
    .url(forResource: Self.dingFile, withExtension: "caf")
    .flatMap { NSSound(contentsOf: $0, byReference: false) }

  private var baseline: [JobID: JobStatus] = [:]
  private var hasRequestedAuthorization = false

  /// Nil during hosted tests to prevent authorization prompts and live notification access.
  private let center: UNUserNotificationCenter?

  /// Assigned after support-directory resolution because the notification delegate may be
  /// registered earlier. Nil during hosted tests to prevent video-record writes.
  var videoRecordStore: VideoRecordStore?

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

  /// Request permission on first enqueue, before the first completion needs to be reported.
  func requestAuthorizationIfNeeded() {
    guard let center, !hasRequestedAuthorization else { return }
    hasRequestedAuthorization = true
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  /// Notify background intent outcomes without a chime. Body-keyed identifiers replace repeats;
  /// the delegate suppresses foreground banners.
  func announceIntentSubmission(title: String, body: String) {
    guard let center else { return }
    // A duplicate can bypass the usual first-enqueue authorization request.
    requestAuthorizationIfNeeded()

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body

    center.add(UNNotificationRequest(
      identifier: "intent-submission-\(body)",
      content: content,
      trigger: nil))
  }

  /// Post findings chosen by FindingAnnouncement. One identifier replaces earlier counts; no
  /// chime. Default click selects Watching.
  func announceFindings(title: String, body: String) {
    guard let center else { return }
    // Watching can find archives before any enqueue has requested permission.
    requestAuthorizationIfNeeded()

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.userInfo = [Self.revealWatchingKey: true]

    center.add(UNNotificationRequest(
      identifier: "watching-findings", content: content, trigger: nil))
  }

  func apply(_ jobs: [Job]) {
    // Seed the baseline silently: jobs absent from the previous snapshot do not emit events.
    for event in NotificationDecision.events(from: baseline, to: jobs) {
      // Record every settled outcome independently of notification availability, using the same
      // snapshot diff.
      if let videoRecordStore,
        let identifier = jobs.first(where: { $0.id == event.job })?.mediaIdentifier
      {
        VideoRecorder.recordCompletion(
          mediaIdentifier: identifier, outcome: event.outcome,
          files: event.files, into: videoRecordStore)
      }

      guard let center else { continue }

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
      if event.outcome == .finished { playChimeIfAllowed() }

      center.add(UNNotificationRequest(
        identifier: event.job.rawValue.uuidString,
        content: content,
        trigger: nil))
    }

    baseline = NotificationDecision.statuses(of: jobs)
  }

  // MARK: - UNUserNotificationCenterDelegate

  /// Suppress foreground banners. Play sound from the posting path because willPresent is not
  /// called for background presentation.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification) async -> UNNotificationPresentationOptions
  {
    // Do not request notification sound; the app plays its chime separately.
    return await MainActor.run { NSApp.isActive ? [] : [.banner] }
  }

  /// Respect Oxbow's per-app sound setting. Direct NSSound playback bypasses Focus/Do Not
  /// Disturb, whose state has no public API. Return to UNNotificationSound if its
  /// silent-playback issue is resolved.
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
    let userInfo = response.notification.request.content.userInfo
    let paths = userInfo[JobNotifier.filesKey] as? [String] ?? []
    let revealsWatching = userInfo[JobNotifier.revealWatchingKey] as? Bool ?? false

    await MainActor.run {
      if revealsWatching {
        NSApp.activate(ignoringOtherApps: true)
        WatchingReveal.shared.request()
        return
      }
      guard !paths.isEmpty else {
        NSApp.activate(ignoringOtherApps: true)
        return
      }
      NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(filePath: $0) })
    }
  }
}
