import Foundation
import Observation
import OxbowKit

/// Derive Watching rows from sweep results, recorded history, and persisted watch state. Other
/// writers update seen asynchronously, so rebuild must reload rather than trust only this
/// model's writes.
@MainActor
@Observable
final class WatchingModel {

  /// One channel's part of the list.
  struct Section: Identifiable, Equatable {
    var login: String
    var displayName: String

    /// Optional stored avatar; sweeps do not fetch profiles to backfill missing values.
    var avatarURL: URL?
    /// Inbox rows with pre-resolved archive state.
    var rows: [Row]

    /// Whole channel history. Derive rows and allRows from one resolved, sorted list so the
    /// inbox is an exact filtered subset.
    var allRows: [Row] = []

    /// Keep fetch failures distinct from a successful empty list.
    var failure: String?
    /// Summary of frozen settings, using the intake's labels and ordering.
    var settingsSummary: String
    /// Stored automatic-download intent, independent of the current sweep's demotion.
    var downloadsAutomatically: Bool

    /// Probe the destination separately: rows without recorded delivery paths and manual
    /// watches may otherwise hide a disconnected volume.
    var disconnectedDestination: String?

    var id: String { login }
  }

  /// One archive, and what it currently is.
  struct Row: Identifiable, Equatable {
    var archive: ChannelArchive
    var state: ArchiveRowState
    var id: String { archive.id }
  }

  /// Minimal sidebar projection avoids invalidation for unrelated section details.
  struct ChannelListing: Identifiable, Equatable {
    var login: String
    var displayName: String
    /// Count actionable rows; the view hides zero badges without hiding the channel.
    var waiting: Int

    var id: String { login }
  }

  /// Sort sidebar channels alphabetically by display name to avoid movement after sweeps.
  static func listings(from sections: [Section]) -> [ChannelListing] {
    sections
      .map { section in
        ChannelListing(
          login: section.login,
          displayName: section.displayName,
          waiting: section.rows.filter { $0.state == .available }.count)
      }
      .sorted {
        $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
      }
  }

  var channelListings: [ChannelListing] { Self.listings(from: sections) }

  private(set) var sections: [Section] = []

  /// Reload watches on every rebuild, including channels whose first sweep has not run.
  private(set) var watches: [Watch] = []

  /// Sum channel waiting counts so the parent badge agrees with its children; queued and
  /// delivered rows do not count.
  var unreadCount: Int {
    channelListings.reduce(0) { $0 + $1.waiting }
  }

  private let store: WatchStore

  /// Require an explicit record store; stopWatching deletes rows and must never guess a path.
  private let videoRecordStore: VideoRecordStore

  /// Resolve image purging at call time because the image store is constructed later. No-op by
  /// default; omitted cleanup leaves cache files without risking record data.
  private let purgeImages: (Set<URL>) -> Void

  /// Remove payloads for dropped record ids; row deletion alone does not remove these separate
  /// files. Optional cleanup may leave unused files.
  private let payloads: PayloadStore?

  private let openIntake: (ChannelArchive, Watch) -> Void

  /// Queue with frozen watch settings; return a refusal message or nil.
  private let queue: (ChannelArchive, Watch) async -> String?

  /// Queue snapshots inform display state only; removing a job must never clear persisted seen
  /// state.
  private var jobs: [Job] = []

  /// Inject direct file probes. VolumeSpace's nearest-existing-ancestor lookup would treat an
  /// unmounted /Volumes path as the boot volume and misclassify it as deleted.
  private let fileAnswer: (URL) -> ArchiveRowState.FileAnswer


  private var dismissed: Set<String> = []

  /// Look up sweep results by watched login; watches, not this snapshot, determine which
  /// sections exist.
  private var latest: [WatchPollResult] = []

  /// Visible reason for a refused Stop Watching action.
  private(set) var stopWatchingFailure: String?

  /// Visible failure when an Ignore/Add seen-state write cannot be read or saved.
  private(set) var markSeenFailure: String?

  /// Last enqueue refusal, cleared by the next Add or rebuild.
  private(set) var submissionFailure: String?

  init(
    store: WatchStore,
    videoRecordStore: VideoRecordStore,
    openIntake: @escaping (ChannelArchive, Watch) -> Void,
    queue: @escaping (ChannelArchive, Watch) async -> String? = { _, _ in nil },
    // Default to absent: claiming present without a real probe would mark every expected path
    // as downloaded.
    fileAnswer: @escaping (URL) -> ArchiveRowState.FileAnswer = { _ in .absent },
    purgeImages: @escaping (Set<URL>) -> Void = { _ in },
    payloads: PayloadStore? = nil
  ) {
    self.store = store
    self.videoRecordStore = videoRecordStore
    self.openIntake = openIntake
    self.queue = queue
    self.fileAnswer = fileAnswer
    self.purgeImages = purgeImages
    self.payloads = payloads
    // Show watched channels before their first sweep arrives.
    rebuild()
  }

  /// Only queue facts that affect archive state: media id, status, and delivered paths.
  private struct JobFacts: Equatable {
    var mediaIdentifier: String?
    var status: JobStatus
    var deliveredFile: URL?

    init(_ job: Job) {
      mediaIdentifier = job.mediaIdentifier
      status = job.status
      deliveredFile = job.deliveredFiles.first
    }
  }

  private var jobFacts: [JobFacts] = []

  /// Rebuild only when JobFacts changes. Comparing whole jobs would react to every progress
  /// tick, causing main-actor disk I/O and prematurely clearing failure banners.
  func updateJobs(_ jobs: [Job]) {
    self.jobs = jobs

    let facts = jobs.map(JobFacts.init)
    guard facts != jobFacts else { return }
    jobFacts = facts

    rebuild()
  }

  /// Replace the current sweep; history is retained separately in the record.
  func apply(_ results: [WatchPollResult]) {
    latest = results

    let found = results.reduce(into: Set<String>()) { ids, result in
      if case .found(let archives) = result.outcome {
        ids.formUnion(archives.map(\.id))
      }
    }
    dismissed.formIntersection(found)

    rebuild()
  }

  func ignore(_ archive: ChannelArchive, from login: String) {
    markSeen(archive.id, in: login, recording: .ignored)
  }

  /// Queue with frozen watch settings, then mark seen. Refusal leaves the row actionable;
  /// successful submission displays queued state instead of disappearing.
  func add(_ archive: ChannelArchive, from login: String) async {
    submissionFailure = nil

    // Read current saved settings before composing; refuse unreadable watch lists visibly.
    let current: [Watch]
    do {
      current = try store.load()
    } catch {
      rebuild()
      markSeenFailure = "Oxbow could not read the watch list: \(error.localizedDescription)"
      return
    }

    // A removed watch is a normal race with the displayed list.
    guard let watch = current.first(where: { $0.login == login }) else { return }

    if let failure = await queue(archive, watch) {
      submissionFailure = failure
      return
    }
    // IntakeAdd already recorded queued state; do not overwrite it with a dismissal.
    markSeen(archive.id, in: login, recording: nil)
  }

  /// Open intake for per-video overrides or trim. Opening counts as handled even if the form is
  /// abandoned.
  func openInIntake(_ archive: ChannelArchive, from login: String) {
    // Record ignored on open; successful submission replaces it with queued.
    guard let watch = markSeen(archive.id, in: login, recording: .ignored) else { return }
    openIntake(archive, watch)
  }

  /// Mark the archive seen and return its watch; nil if missing or unreadable. Rebuild after
  /// the persist attempt. Failed saves report markSeenFailure and reconcile the row back to
  /// persisted state.
  @discardableResult
  private func markSeen(
    _ id: String, in login: String, recording state: WatchState?
  ) -> Watch? {
    dismissed.insert(id)

    var current: [Watch]
    do {
      current = try store.load()
    } catch {
      // Rebuild before setting the failure message because rebuild clears banners.
      rebuild()
      markSeenFailure = "Oxbow could not read the watch list: \(error.localizedDescription)"
      return nil
    }

    guard let index = current.firstIndex(where: { $0.login == login }) else {
      rebuild()
      return nil
    }

    current[index] = current[index].marking([id])
    // On save failure, rebuild prunes the dismissal against disk and restores the row. Set
    // markSeenFailure afterwards so the banner survives; callers may still open intake.
    do {
      try store.save(current)
    } catch {
      let result = current[index]
      rebuild()
      markSeenFailure = """
        Oxbow could not save the watch list, so this is still here. \
        \(error.localizedDescription)
        """
      return result
    }

    // Record state only after the watch save succeeds. Include the channel-owned video row so
    // removeWatch can clean up its state later.
    if let state, var library = try? videoRecordStore.load() {
      library.record(VideoRecord(id: id, login: login))
      library.setState(state, for: id)
      try? videoRecordStore.save(library)
    }

    let result = current[index]
    rebuild()
    return result
  }

  /// Remove the watch and unused history/cache entries, preserving delivered files and records
  /// still backed by downloads. Refuse unreadable watch lists rather than overwriting other
  /// channels.
  func stopWatching(_ login: String) {
    let existing: [Watch]
    do {
      existing = try store.load()
    } catch {
      stopWatchingFailure = """
        Oxbow could not read the watch list, so \(login) was not stopped. \
        \(error.localizedDescription)
        """
      return
    }

    // Retain surviving watches for the avatar keep-set.
    let surviving = existing.filter { $0.login != login }

    do {
      try store.save(surviving)
    } catch {
      stopWatchingFailure = "Oxbow could not save the watch list: \(error.localizedDescription)"
      return
    }

    // Clean history only after saving the watch removal. Preserve delivered and job-backed
    // records. Keep video-record load-modify-save synchronous on the main actor; cleanup
    // failure must not undo the committed unwatch.
    if var library = try? videoRecordStore.load() {
      // Protect records for in-flight jobs that have no delivered file yet.
      let jobbed = Set(jobFacts.compactMap(\.mediaIdentifier))

      // Capture ids before mutation to identify which payloads become unused.
      let before = Set(library.videos.keys)
      library.removeWatch(login: login, keepingVideosWithJobs: jobbed)
      let dropped = before.subtracting(library.videos.keys)

      // Purge only after the record save succeeds. Keep images referenced by surviving video
      // rows and watch avatars; delete payloads only for dropped ids. Failed saves must retain
      // those potentially irreplaceable cached files.
      if (try? videoRecordStore.save(library)) != nil {
        purgeImages(library.referencedImageURLs()
          .union(surviving.compactMap(\.avatarURL)))
        payloads?.remove(ids: dropped)
      }
    }


    // Remove this watch's persisted seen ids from the dismissal overlay so re-adding it cannot
    // inherit stale dismissals.
    if let removed = existing.first(where: { $0.login == login }) {
      dismissed.subtract(removed.seen)
    }

    // Stale results for removed logins are inert because rebuild iterates current watches.
    rebuild()
  }

  /// Explicitly reload after other store handles write, including Add Channel, rather than
  /// waiting for another sweep.
  func refresh() {
    rebuild()
  }

  /// Reload current watches; retain the previous snapshot if reading fails.
  private func refreshWatches() {
    if let loaded = try? store.load() {
      watches = loaded
    }
  }

  /// Combine recorded history and live archives for one channel. Prefer live entries for
  /// current broadcast status, and resolve row state before applying inbox visibility rules.
  private func rows(
    for watch: Watch, liveArchives: [ChannelArchive], library: VideoLibrary
  ) -> (rows: [Row], allRows: [Row]) {
    let live = Dictionary(liveArchives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let recorded = library.videos.filter { $0.value.login == watch.login }

    // Union live results with history. Best-effort recording may have failed, so live rows must
    // not depend on already being persisted.
    let candidates: [(archive: ChannelArchive, record: VideoRecord?)] =
      liveArchives.map { ($0, recorded[$0.id]) }
      + recorded.values.filter { live[$0.id] == nil }.map { (Self.archive(from: $0), $0) }

    // Resolve filesystem-backed state before deciding visibility.
    let resolved = candidates
      .map { candidate -> (archive: ChannelArchive, state: ArchiveRowState) in
        let resolved = ArchiveRowState.state(
          for: candidate.archive, jobs: jobs,
          recordedPath: candidate.record?.deliveredPath,
          // Derive expected paths only without recorded delivery paths; formatting is per-row
          // work.
          expectedPath: candidate.record?.deliveredPath == nil
            ? Self.expectedPath(for: candidate.archive, watch: watch)
            : nil,
          file: fileAnswer)

        // Turn otherwise-offerable non-live archives into expired headstones; keep
        // queued/running states intact.
        let isLive = live[candidate.archive.id] != nil
        guard !isLive, !resolved.holdsAFile, resolved.isFetchable else {
          return (candidate.archive, resolved)
        }
        return (candidate.archive, .expired)
      }

    // Visibility precedence: downloaded, in flight, dismissal, recorded state, legacy seen,
    // then live presence. Legacy seen bridges writes not yet migrated into the record; remove
    // it only when all producers stop writing that set.
    func belongsInTheDefaultView(_ row: (archive: ChannelArchive, state: ArchiveRowState)) -> Bool {
      if row.state.holdsAFile { return true }
      if row.state == .queued || row.state == .running { return true }
      if dismissed.contains(row.archive.id) { return false }
      if let state = library.watchStates[row.archive.id] { return state.isVisibleByDefault }
      if watch.seen.contains(row.archive.id) { return false }
      return live[row.archive.id] != nil
    }

    let shown = resolved.filter(belongsInTheDefaultView)

    // Apply the same newest-first ordering to inbox and full history.
    func newestFirst(
      _ items: [(archive: ChannelArchive, state: ArchiveRowState)]
    ) -> [Row] {
      items
        .map { Row(archive: $0.archive, state: $0.state) }
        .sorted { $0.archive.publishedAt > $1.archive.publishedAt }
    }

    return (newestFirst(shown), newestFirst(resolved))
  }

  /// Use FileAnswer's unknown result for disconnection; absent means missing rather than
  /// unverifiable.
  private func disconnectedDestination(for watch: Watch) -> String? {
    // Probe inside the destination so resolve checks its availability, not merely the
    // always-present /Volumes parent. The probe file need not exist.
    let probe = watch.settings.destination.appending(path: ".oxbow-destination-probe")
    guard case .unknown(let volumeName) = fileAnswer(probe) else { return nil }
    return volumeName
  }

  /// Recognize pre-record downloads at their deterministic expected path. Mirror intake's
  /// display-name, date, title, and suffix rules using the current calendar/timezone.
  private static func expectedPath(for archive: ChannelArchive, watch: Watch) -> String {
    let base = OutputNaming.baseName(
      streamer: watch.displayName,
      date: archive.publishedAt,
      title: archive.title,
      calendar: .current,
      reservingSuffixBytes: OutputSuffix.longestBytes)
    return watch.settings.destination
      .appending(path: base + OutputSuffix.video)
      .path(percentEncoded: false)
  }

  /// Adapt remembered metadata for archives absent from the live sweep. recorded is a fallback
  /// status; row availability comes from stored and filesystem evidence.
  private static func archive(from record: VideoRecord) -> ChannelArchive {
    ChannelArchive(
      id: record.id,
      title: record.title ?? record.id,
      duration: .seconds(record.durationSeconds ?? 0),
      publishedAt: record.publishedAt ?? .distantPast,
      status: .recorded,
      thumbnailURL: record.thumbnailURLs.first,
      categoryName: record.categoryName)
  }


  private func rebuild() {
    stopWatchingFailure = nil
    markSeenFailure = nil
    submissionFailure = nil

    refreshWatches()

    // Reconcile dismissed ids against all current watch seen sets, including unmarks from other
    // observers.
    let stillSeen = watches.reduce(into: Set<String>()) { $0.formUnion($1.seen) }
    dismissed.formIntersection(stillSeen)

    // Load history once for all sections; a read failure uses an empty library.
    let library = (try? videoRecordStore.load()) ?? VideoLibrary()

    sections = watches.map { watch in
      let outcome = latest.first(where: { $0.login == watch.login })?.outcome
      switch outcome {
      case .found(let archives):
        let built = rows(for: watch, liveArchives: archives, library: library)
        return Section(
          login: watch.login, displayName: watch.displayName,
          avatarURL: watch.avatarURL,
          rows: built.rows,
          allRows: built.allRows,
          failure: nil, settingsSummary: settingsSummary(for: watch.settings),
          downloadsAutomatically: watch.downloadsAutomatically,
          disconnectedDestination: disconnectedDestination(for: watch))
      case .failed(let error):
        return Section(
          login: watch.login, displayName: watch.displayName,
          avatarURL: watch.avatarURL,
          rows: [], failure: error.localizedDescription,
          settingsSummary: settingsSummary(for: watch.settings),
          downloadsAutomatically: watch.downloadsAutomatically,
          disconnectedDestination: disconnectedDestination(for: watch))
      case nil:
        // Show recorded history before a channel's first sweep.
        let built = rows(for: watch, liveArchives: [], library: library)
        return Section(
          login: watch.login, displayName: watch.displayName,
          avatarURL: watch.avatarURL,
          rows: built.rows,
          allRows: built.allRows,
          failure: nil, settingsSummary: settingsSummary(for: watch.settings),
          downloadsAutomatically: watch.downloadsAutomatically,
          disconnectedDestination: disconnectedDestination(for: watch))
      }
    }
  }

  /// Match intake summary ordering: output/chat size, cap, destination.
  private func settingsSummary(for settings: Watch.Settings) -> String {
    let outputLabel: String
    switch settings.output {
    case .videoWithChat: outputLabel = "Video + chat"
    case .video: outputLabel = "Video"
    }

    var summary = "\(outputLabel) · \(settings.qualityCap.label)"
    if settings.output == .videoWithChat {
      summary += " · \(settings.chatSize.rawValue.capitalized) chat"
    }
    summary += " · \(settings.destination.lastPathComponent)"
    return summary
  }
}
