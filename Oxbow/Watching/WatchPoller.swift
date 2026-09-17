import Foundation
import Observation
import OxbowKit

/// Schedule and publish app-lifetime sweeps; policy and fetching live in WatchPollPolicy and
/// WatchPoll. No background launch agent.
@MainActor
@Observable
final class WatchPoller {

  /// Latest sweep, replaced wholesale; empty before the first result.
  private(set) var results: [WatchPollResult] = []

  /// True while a sweep is in flight, so the UI can say so rather than looking
  /// idle for however long a handful of network round trips takes.
  private(set) var isSweeping = false

  private(set) var lastPolled: Date?

  /// Per-sweep automatic-download demotions, replaced rather than accumulated so recovered
  /// destinations resume normally.
  private(set) var demotions: [String: AutoDownloadPolicy.Reason] = [:]

  /// Announced ids for this session, replaced by each FindingAnnouncement decision to avoid
  /// repeated hourly notices.
  private var announced: Set<String> = []

  /// Automatic submission refusals by archive id, shown separately from jobs that fail after
  /// enqueue.
  private(set) var submissionFailures: [String: String] = [:]

  private let store: WatchStore
  private let feed: ChannelFeed
  private let now: () -> Date
  private var loop: Task<Void, Never>?

  /// All record-store handles use AppComposition's path and synchronous main-actor
  /// load-modify-save. Store structs are stateless; the shared file and write ordering are what
  /// matter.
  let videoRecordStore: VideoRecordStore

  /// Injected announcement sink for tests without notification access.
  private let announce: (FindingAnnouncement.Message) -> Void

  /// Require explicit collaborators and record store; there is no safe default persistence
  /// path.
  init(
    store: WatchStore, feed: ChannelFeed, videoRecordStore: VideoRecordStore,
    now: @escaping () -> Date = Date.init,
    announce: @escaping (FindingAnnouncement.Message) -> Void = { message in
      QueueHost.shared.notifyFindings(title: message.title, body: message.body)
    }
  ) {
    self.store = store
    self.feed = feed
    self.videoRecordStore = videoRecordStore
    self.now = now
    self.announce = announce
  }

  /// Live stores and an ephemeral feed session for current Twitch results.
  static func live(supportDirectory: URL) -> WatchPoller {
    let configuration = URLSessionConfiguration.ephemeral
    // Bound each sequential request to 15 seconds so one unreachable channel does not stall the
    // entire sweep for a minute.
    configuration.timeoutIntervalForRequest = 15
    configuration.waitsForConnectivity = false
    let session = URLSession(configuration: configuration)
    let watchStore = WatchStore(
      fileURL: AppComposition.watchStoreURL(supportDirectory: supportDirectory))
    let videoRecordStore = VideoRecordStore(
      fileURL: AppComposition.videoRecordURL(supportDirectory: supportDirectory))
    migrateSeenIfNeeded(watches: (try? watchStore.load()) ?? [], into: videoRecordStore)
    return WatchPoller(
      store: watchStore,
      feed: ChannelFeed(fetch: { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
          throw ChannelFeedError.malformedPayload(snippet: "")
        }
        return (data, http)
      }),
      videoRecordStore: videoRecordStore)
  }

  /// Merge legacy seen ids without overwriting recorded states. Safe on each launch; retain
  /// legacy data for recovery.
  static func migrateSeenIfNeeded(watches: [Watch], into store: VideoRecordStore) {
    guard let library = try? store.load() else { return }
    let migrated = SeenMigration.migrate(watches: watches, into: library)
    guard migrated != library else { return }
    try? store.save(migrated)
  }

  /// Start one loop: sweep now, then at WatchPollPolicy.interval while the app runs.
  func start() {
    guard loop == nil else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.sweepIfDue()
        try? await Task.sleep(for: .seconds(WatchPollPolicy.interval))
      }
    }
  }

  func stop() {
    loop?.cancel()
    loop = nil
  }

  /// Cancel the loop when its owner is released.
  isolated deinit {
    loop?.cancel()
  }

  /// Bypass interval throttling. If already sweeping, return immediately without awaiting or
  /// queuing another sweep; results may still be from the previous sweep.
  func refreshNow() async {
    await sweep()
  }

  private func sweepIfDue() async {
    guard WatchPollPolicy.shouldPoll(now: now(), lastPolled: lastPolled) else { return }
    await sweep()
  }

  private func sweep() async {
    guard !isSweeping else { return }

    // An unreadable watch list currently behaves as empty, clearing results. Decode recovery is
    // handled by WatchStore; try? also suppresses I/O failures here.
    let watches = (try? store.load()) ?? []

    // Migrate every sweep to catch Only new seeds and other seen writes made since launch.
    // Existing recorded state is preserved.
    Self.migrateSeenIfNeeded(watches: watches, into: videoRecordStore)

    guard !watches.isEmpty else {
      // Clear demotions on this early return, which bypasses actOnFindings.
      results = []
      demotions = [:]
      // Clear announcements so re-added watches can announce again.
      announced = []
      submissionFailures = [:]
      return
    }

    isSweeping = true
    let swept = await WatchPoll.sweep(watches) { login in
      do {
        return .success(try await feed.archives(forLogin: login))
      } catch let error as ChannelFeedError {
        return .failure(error)
      } catch {
        // Classify transport failures as unreachable, not as a Twitch response error.
        return .failure(.unreachable(error.localizedDescription))
      }
    }
    results = swept
    // Record only successful found results. The empty-array guard currently also masks
    // failures; if either guard changes, verify failed sweeps still cannot record sightings.
    for result in swept {
      guard case .found(let archives) = result.outcome else { continue }
      Self.record(
        archives: archives, forLogin: result.login,
        displayName: result.displayName, seenAt: now(), into: videoRecordStore)
    }
    lastPolled = now()
    let submitted = await actOnFindings(watches: watches, results: swept)

    // Announce after automatic submission so queued archives are excluded from waiting counts.
    let decision = FindingAnnouncement.decide(
      results: swept, watches: watches, submitted: submitted, alreadyAnnounced: announced)
    announced = decision.announced
    if let message = decision.message { announce(message) }

    isSweeping = false
  }

  /// Decide automatic eligibility and return submitted ids for announcement exclusion. Use the
  /// sweep's watch snapshot and fresh capacity checks; an edit during an await may affect only
  /// the next sweep. Re-read stores separately before write-back.
  @discardableResult
  private func actOnFindings(watches: [Watch], results: [WatchPollResult]) async -> Set<String> {
    var submitted: Set<String> = []
    let floor = Preferences().freeSpaceFloor
    let resultsByLogin = Dictionary(uniqueKeysWithValues: results.map { ($0.login, $0) })

    // Resolve once for job filtering and submission. Even without an engine, evaluate
    // destination/floor demotions.
    let readyState = await QueueHost.shared.ready()
    let controller: QueueController? = {
      guard case .ready(let controller) = readyState else { return nil }
      return controller
    }()

    var newDemotions: [String: AutoDownloadPolicy.Reason] = [:]
    var toSubmit: [(watch: Watch, archives: [ChannelArchive])] = []

    for watch in watches {
      // Filter seen ids and archives with failed jobs before automatic policy. Failed feed
      // results yield no submissions without erasing the separately reported feed error.
      let unseen = Self.unseenFindings(for: watch, resultsByLogin: resultsByLogin)
      let findings = Self.excludingArchivesWithFailedJobs(
        unseen, jobs: controller?.jobs ?? [])
      let destination = watch.settings.destination
      let destinationExists = FileManager.default.fileExists(atPath: destination.path)
      // Treat unknown capacity as zero so unattended work remains paused until it can be
      // checked.
      let availableBytes = VolumeSpace.live.availableBytes(destination) ?? 0

      // Scope failure history to this channel so another channel's restrictions cannot demote
      // it.
      let mine = (controller?.jobs ?? []).filter { job in
        guard let media = job.mediaIdentifier else { return false }
        return resultsByLogin[watch.login]?.archives.contains { $0.id == media } ?? false
      }

      switch AutoDownloadPolicy.decide(
        watch: watch, findings: findings, availableBytes: availableBytes,
        destinationExists: destinationExists,
        contentRestricted: AutoDownloadPolicy.isContentRestricted(jobs: mine),
        floor: floor)
      {
      case .notAutomatic:
        continue
      case .demoted(let reason):
        newDemotions[watch.login] = reason
      case .submit(let archives):
        guard !archives.isEmpty else { continue }
        toSubmit.append((watch, archives))
      }
    }

    // Publish the complete demotion set once.
    demotions = newDemotions

    guard !toSubmit.isEmpty else { return submitted }

    guard let controller else { return submitted }

    // Submit sequentially to avoid a burst of metadata requests ahead of serialized downloads.
    var newFailures: [String: String] = [:]
    for (watch, archives) in toSubmit {
      let result = await ArchiveSubmission.submit(archives, for: watch, into: controller)
      for archive in result.queued {
        submitted.insert(archive.id)
        markSubmitted(archive.id, login: watch.login)
      }
      newFailures.merge(result.failures) { current, _ in current }
    }

    // Replace failures each sweep so resolved refusals disappear.
    submissionFailures = newFailures
    return submitted
  }

  /// Exclude archives with failed jobs from automatic submission. Failure recovery returns them
  /// to the inbox for manual retry, not another unattended attempt each sweep. Cancelled jobs
  /// do not trigger this filter; no seen state is changed here.
  nonisolated static func excludingArchivesWithFailedJobs(
    _ findings: [ChannelArchive], jobs: [Job]
  ) -> [ChannelArchive] {
    let failedMediaIdentifiers = Set(
      jobs.compactMap { $0.status == .failed ? $0.mediaIdentifier : nil })
    return findings.filter { !failedMediaIdentifiers.contains($0.id) }
  }

  /// Filter sweep results through this watch's seen set; WatchPoll returns all archives.
  /// Missing or failed results yield no findings.
  nonisolated static func unseenFindings(
    for watch: Watch, resultsByLogin: [String: WatchPollResult]
  ) -> [ChannelArchive] {
    watch.findings(in: resultsByLogin[watch.login]?.archives ?? [])
  }

  /// Reload immediately before marking submitted ids seen; earlier snapshots may predate other
  /// writes during metadata awaits. Saving is best effort: a lost mark can cause a duplicate
  /// after the original job finishes.
  private func markSubmitted(_ archiveID: String, login: String) {
    guard var current = try? store.load() else { return }
    guard let index = current.firstIndex(where: { $0.login == login }) else { return }
    current[index] = current[index].marking([archiveID])
    try? store.save(current)
  }

  /// Best-effort recording of all observed archives, including handled ones, for history after
  /// Twitch expiry.
  static func record(
    archives: [ChannelArchive],
    forLogin login: String,
    displayName: String?,
    seenAt: Date,
    into store: VideoRecordStore)
  {
    // Empty input must not record a sighting. This also masks a failed result flattened to [];
    // verify the caller's found-only guard if changing this one.
    guard !archives.isEmpty else { return }
    guard var library = try? store.load() else { return }

    for archive in archives {
      library.record(VideoRecord(
        id: archive.id,
        login: login,
        displayName: displayName,
        title: archive.title,
        durationSeconds: Int(archive.duration.components.seconds),
        publishedAt: archive.publishedAt,
        categoryName: archive.categoryName,
        thumbnailURLs: [archive.thumbnailURL].compactMap { $0 },
        lastSeenOnTwitch: seenAt))
    }

    try? store.save(library)
  }
}
