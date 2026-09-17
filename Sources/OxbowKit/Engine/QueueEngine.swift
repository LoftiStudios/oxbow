import Foundation

/// What the composite step's Finder-reveal item should show. See
/// `QueueEngine.revealTarget(forJob:)` for how this is decided.
public enum RevealTarget: Equatable, Sendable {
  /// Reveal pieces when present, otherwise their directory before the first fragment lands.
  case retained(directory: URL, pieces: [URL])
  /// After retention cleanup, reveal the delivered file.
  case delivered(URL)
}

/// Own queue state and side effects; Scheduler supplies pure admission and transition rules.
public actor QueueEngine {

  public struct Configuration: Sendable {
    public var helperExecutable: URL
    public var ffmpegPath: URL
    public var workspace: Workspace
    /// - Important: Keep the queue file outside disposable job workspaces swept at startup.
    public var store: QueueStore
    public var makeProcess: @Sendable () -> HelperProcessing
    /// Keep the Mac awake while steps run; injectable for tests.
    public var sleepAssertion: any SleepAsserting

    public init(
      helperExecutable: URL,
      ffmpegPath: URL,
      workspace: Workspace,
      store: QueueStore,
      makeProcess: @escaping @Sendable () -> HelperProcessing,
      sleepAssertion: any SleepAsserting = SystemSleepAssertion())
    {
      self.helperExecutable = helperExecutable
      self.ffmpegPath = ffmpegPath
      self.workspace = workspace
      self.store = store
      self.makeProcess = makeProcess
      self.sleepAssertion = sleepAssertion
    }
  }

  /// Where a step's finished output ends up on success.
  private enum MoveOutcome {
    /// The step has no destination outside the workspace — its output stays
    /// where it is, as an intermediate for a later step to consume.
    case notApplicable
    case moved(URL)
    /// Delivery failed. Never treat this as an intermediate with no destination or report the
    /// step as successfully saved.
    case failed(String)
  }

  private let configuration: Configuration

  /// The only route to `Workspace`'s removal methods — see `TeardownJournal`.
  private let journal: TeardownJournal

  /// What is retained on disk for an interrupted composite, and where a
  /// resumed one picks up — see `ResumeLedger`.
  private let ledger: ResumeLedger

  /// Builds each step's `StepContext` — see `StepContextBuilder`.
  private let contexts: StepContextBuilder

  private var jobs: [Job] = []
  /// Track live helpers, not their driving Tasks: only HelperProcessing.cancel() stops child
  /// processes.
  private var running: [StepID: HelperProcessing] = [:] {
    // Derive the sleep assertion from running at every mutation; setActive is idempotent.
    didSet { configuration.sleepAssertion.setActive(!running.isEmpty) }
  }
  /// Last time `heartbeat` wrote a line for a step — see its doc comment.
  private var lastHeartbeatAt: [StepID: ContinuousClock.Instant] = [:]
  private var observers: [UUID: AsyncStream<[Job]>.Continuation] = [:]
  private var saveTask: Task<Void, Never>?
  /// Jobs whose workspace a `cancel(job:)` wants removed, but that still had
  /// a step running when the kill signals were sent. `finish` clears one out
  /// once the last such step actually stops. See `removeJobWorkspaceIfSettled`.
  private var jobsAwaitingWorkspaceRemoval: Set<JobID> = []
  /// Permanent shutdown flag: stop admission and ignore kill outcomes so persisted running
  /// steps reconcile as interrupted.
  private var isShuttingDown = false

  public init(configuration: Configuration) {
    self.configuration = configuration
    let journal = TeardownJournal(workspace: configuration.workspace)
    self.journal = journal
    let ledger = ResumeLedger(workspace: configuration.workspace, journal: journal)
    self.ledger = ledger
    self.contexts = StepContextBuilder(
      workspace: configuration.workspace,
      ffmpegPath: configuration.ffmpegPath,
      ledger: ledger)
  }

  // MARK: - Public surface

  public var currentJobs: [Job] { jobs }

  /// True when nothing is running and nothing further can be admitted.
  public var isIdle: Bool {
    running.isEmpty && Scheduler.admissible(jobs: jobs, running: []).isEmpty
  }

  /// makeStream provides the continuation for actor-isolated registration without an escaping
  /// builder mutation. Buffer only the newest complete snapshot; superseded progress snapshots
  /// carry no additional state.
  public func makeSnapshots() -> AsyncStream<[Job]> {
    let (stream, continuation) = AsyncStream<[Job]>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    observers[id] = continuation
    continuation.yield(jobs)
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeObserver(id) }
    }
    return stream
  }

  /// Sweep scratch workspaces, load and reconcile the queue, then start work. `runsWork=false`
  /// still sweeps scratch space but publishes saved jobs without reconciliation or scheduling.
  /// Resume retention is handled separately.
  public func start(runsWork: Bool = true) async throws {
    configuration.workspace.removeAll()

    let loaded = try configuration.store.load()

    guard runsWork else {
      jobs = loaded
      // Fixture startup bypasses tick(), so publish explicitly.
      publish()
      return
    }

    jobs = Reconciler.reconcile(loaded) { Self.isUsableArtifact($0) }

    removeOrphanedResumeDirectories()

    tick()
  }

  /// Remove retention directories only when no loaded job owns them, including after
  /// queue-store loss. Unlike disposable workspaces, retained pieces for cancelled or failed
  /// jobs must survive startup.
  private func removeOrphanedResumeDirectories() {
    let known = Set(jobs.map { $0.id.rawValue.uuidString })
    let resumeRoot = configuration.workspace.resumeRoot
    guard let contents = try? FileManager.default.contentsOfDirectory(
      at: resumeRoot, includingPropertiesForKeys: [.isDirectoryKey])
    else { return }

    for url in contents {
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
      else { continue }
      guard !known.contains(url.lastPathComponent) else { continue }
      try? FileManager.default.removeItem(at: url)
    }
  }

  /// Read the current log tail through the engine; workspace paths may disappear during
  /// cleanup.
  public func log(for step: StepID, lines: Int = 200) async -> String? {
    guard let location = locate(step) else { return nil }
    let url = configuration.workspace.logFile(job: jobs[location.job].id, step: step)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let contents = await StepLog(fileURL: url).tail(lines: lines)
    return contents.isEmpty ? nil : contents
  }

  public func enqueue(_ template: JobTemplate, title: String) {
    let job = template.makeJob(
      id: JobID(rawValue: UUID()),
      title: title,
      created: Date(),
      nextStepID: { StepID(rawValue: UUID()) })
    jobs.append(job)
    tick()
  }

  public func retry(step id: StepID) {
    Scheduler.retry(id, in: &jobs)
    tick()
  }

  /// Retries every unfinished step of a job. See `Scheduler.retry(job:in:)`
  /// for why retry at this level cannot be "retry the step that broke".
  public func retry(job id: JobID) {
    Scheduler.retry(job: id, in: &jobs)
    tick()
  }

  public func cancel(step id: StepID) async {
    // Mark cancelled before awaiting termination. finish() may arrive during the grace period
    // and must not overwrite cancellation with a signal failure.
    Scheduler.cancel(id, in: &jobs)
    tick()

    await running[id]?.cancel()
  }

  public func cancel(job id: JobID) async {
    guard let job = jobs.first(where: { $0.id == id }) else { return }

    // Set all unfinished steps cancelled before awaiting any helper termination.
    Scheduler.cancel(job: id, in: &jobs)
    tick()

    let processes = job.steps.compactMap { running[$0.id] }

    // Cancel concurrently so grace periods overlap rather than accumulate.
    await withTaskGroup(of: Void.self) { group in
      for process in processes {
        group.addTask { await process.cancel() }
      }
    }

    // Delete only after all writers exit; a helper ignoring SIGTERM may still be alive here.
    removeJobWorkspaceIfSettled(id)

    // Cleanup can clear artifact references; publish and save the updated state.
    tick()
  }

  /// Cancel running jobs before removing queue entries and workspaces. Preserve delivered
  /// files. Batch selection removal into one publication and save; confirmation belongs to the
  /// caller.
  public func remove(jobs ids: Set<JobID>) async {
    // Job removal reclaims retention even if its queue entry is already absent.
    for id in ids { journal.removeResumable(id) }

    let doomed = jobs.filter { ids.contains($0.id) }
    guard !doomed.isEmpty else { return }

    // Cancel live helpers concurrently so their grace periods overlap.
    let processes = doomed.flatMap { job in job.steps.compactMap { running[$0.id] } }
    if !processes.isEmpty {
      for job in doomed { Scheduler.cancel(job: job.id, in: &self.jobs) }
      await withTaskGroup(of: Void.self) { group in
        for process in processes {
          group.addTask { await process.cancel() }
        }
      }
    }

    // Clear running entries before scheduling replacements. Late completion callbacks safely
    // return when their steps no longer exist.
    for job in doomed {
      for step in job.steps { running[step.id] = nil }
    }

    self.jobs.removeAll { ids.contains($0.id) }
    for id in ids { journal.removeJob(id) }

    tick()
  }

  /// Await helper cancellation and final persistence before exiting. Preserve in-flight steps
  /// as running so startup reconciles them to failed(interrupted), not user-cancelled or
  /// crashed. Suppress completion outcomes during shutdown to avoid racing the final save.
  /// Cancel helpers concurrently so grace periods overlap.
  public func shutDown() async {
    isShuttingDown = true

    let processes = Array(running.values)
    await withTaskGroup(of: Void.self) { group in
      for process in processes {
        group.addTask { await process.cancel() }
      }
    }

    await flush()

    // Release the assertion explicitly: shutdown intentionally retains running entries for
    // interrupted-state persistence, so their didSet cannot release it.
    configuration.sleepAssertion.setActive(false)
  }

  /// Flush pending state immediately. Termination must call shutDown() to stop helpers first.
  public func flush() async {
    // Clear saveTask before awaiting it, then loop: actor reentrancy can install another save
    // during the await. Clearing afterwards could discard a new task that later overwrites
    // final state.
    while let pending = saveTask {
      saveTask = nil
      pending.cancel()
      await pending.value
    }
    try? configuration.store.save(jobs)
  }

  // MARK: - The single drive point

  /// Drive admission after mutations, then publish and schedule persistence.
  private func tick() {
    // Do not launch new helpers while shutdown is cancelling existing ones.
    if !isShuttingDown {
      for id in Scheduler.admissible(jobs: jobs, running: Set(running.keys)) {
        launch(id)
      }
    }
    // Publish before saving, in that order, so observers and the queue file agree —
    // and so a removal survives a quit that happens before the debounce fires.
    publish()
    scheduleSave()
  }

  private func launch(_ id: StepID) {
    guard let location = locate(id) else { return }
    let job = jobs[location.job]
    let step = job.steps[location.step]

    // Recheck queued status: synchronous launch failure can re-enter tick() and launch another
    // step from the outer admission snapshot.
    guard step.status == .queued else { return }

    let context: StepContext
    do {
      context = try makeContext(job: job, step: step)
    } catch let error as StepWiringError {
      completeStep(id, outcome: .failed(StepFailure(
        kind: .launchFailed("\(error)"),
        summary: "Wiring bug: this step's inputs did not match its dependencies.")))
      return
    } catch let error as SourceChangedError {
      completeStep(id, outcome: .failed(StepFailure(
        kind: .noArtifact,
        summary: error.reason ?? "The source changed since this download started. Start it again.")))
      return
    } catch {
      completeStep(id, outcome: .failed(StepFailure(
        kind: .launchFailed("\(error)"),
        summary: "Could not create a working directory.")))
      return
    }

    // Remove source and render after assemble context succeeds, before spawning. Only pieces
    // and sidecar remain needed; early cleanup bounds recovery disk usage
    // (docs/design/resume.md §5).
    if case .assemble = step.kind {
      journal.removeSpentInputs(of: job)
    }

    jobs[location.job].steps[location.step].status = .running

    // HelperProcess is single-use; its cancellation flag never resets.
    let process = configuration.makeProcess()

    // Choose executable and output dialect for direct FFmpeg steps.
    let executable: URL
    let dialect: OutputDialect
    switch step.kind {
    case .composite(let request):
      executable = configuration.ffmpegPath
      dialect = .ffmpeg(duration: request.duration)
    case .assemble:
      executable = configuration.ffmpegPath
      dialect = .ffmpeg(duration: .seconds(0))
    case .downloadVideo, .downloadClip, .downloadChat, .renderChat:
      executable = configuration.helperExecutable
      dialect = .helper
    }

    let launch = Launch(
      executable: executable,
      arguments: ArgumentBuilder.arguments(for: step.kind, context: context),
      workingDirectory: context.stepTempDirectory,
      dialect: dialect)

    running[id] = process
    Task { [weak self] in
      guard let self else { return }
      await self.execute(id, process: process, launch: launch, context: context)
    }
  }

  private func execute(
    _ id: StepID,
    process: HelperProcessing,
    launch: Launch,
    context: StepContext)
    async
  {
    do {
      let log = context.log
      let result = try await process.run(launch) { [weak self] line in
        switch line {
        case .status(let progress):
          // Keep frequent status lines in progress state; heartbeat emits occasional log
          // summaries.
          await self?.updateProgress(id, progress)
          await self?.heartbeat(id, progress, log: log)
        case .log(let level, let message):
          await log?.append("[\(level)] \(message)")
        case .ffmpeg(let message):
          await log?.append("<FFMPEG> \(message)")
        }
      }
      await log?.close()
      finish(id, result: result, context: context)
    } catch {
      // A thrown run has no exit status; report its error directly. Apply the same shutdown and
      // finalized-step guards as finish after the await.
      guard !isShuttingDown else { return }
      guard isStillRunning(id) else {
        abandonAlreadyFinalizedStep(id)
        return
      }
      completeStep(id, outcome: .failed(StepFailure(
        kind: .launchFailed("\(error)"),
        summary: "The tool failed to start.",
        detail: "\(error)")))
    }
  }

  private func updateProgress(_ id: StepID, _ progress: StepProgress) {
    guard let location = locate(id) else { return }
    jobs[location.job].steps[location.step].progress = progress
    publish()
  }

  /// How often a running step's progress gets a line in its own `StepLog` —
  /// see `heartbeat` below.
  private static let heartbeatInterval: Duration = .seconds(15)

  /// Log periodic phase, fraction, and encoding-speed summaries for diagnosing slow or stalled
  /// work; finer updates remain in the progress UI.
  private func heartbeat(_ id: StepID, _ progress: StepProgress, log: StepLog?) async {
    guard let log else { return }

    // Seed heartbeat timing without logging the first update, so short steps produce no
    // heartbeat noise.
    let now = ContinuousClock.now
    guard let last = lastHeartbeatAt[id] else {
      lastHeartbeatAt[id] = now
      return
    }
    guard now - last >= Self.heartbeatInterval else { return }
    lastHeartbeatAt[id] = now

    var parts: [String] = []
    if let phase = progress.phase { parts.append(phase) }
    if let fraction = progress.fraction { parts.append("\(Int((fraction * 100).rounded()))%") }
    if let speed = progress.speed { parts.append(String(format: "%.2fx realtime", speed)) }
    if let remaining = progress.remaining {
      parts.append("\(Int(remaining.components.seconds))s remaining")
    }
    guard !parts.isEmpty else { return }
    await log.append("[progress] " + parts.joined(separator: " · "))
  }

  private func finish(_ id: StepID, result: RunResult, context: StepContext) {
    // Shutdown-triggered exits must leave running state for startup reconciliation. Return
    // without finalized-step cleanup or tick().
    guard !isShuttingDown else { return }

    // Check before delivery: cancellation may have finalized the step during run(), and a late
    // artifact must not be moved or overwrite its status.
    guard isStillRunning(id) else {
      abandonAlreadyFinalizedStep(id)
      return
    }

    guard let location = locate(id) else {
      running[id] = nil
      lastHeartbeatAt[id] = nil
      return
    }
    let job = jobs[location.job]
    let step = job.steps[location.step]

    // Require a usable artifact; helper exit status alone is insufficient.
    let produced = Self.isUsableArtifact(context.outputFile)

    // Composite pieces need samples, not just non-empty ftyp/moov headers. Check trun counts
    // without decoding; unreadable or frameless pieces must not reach concat and silently
    // truncate delivery.
    let framelessPiece: Bool
    if produced, case .composite = step.kind {
      framelessPiece = ((try? FragmentedMP4.index(of: context.outputFile))?.frameCount ?? 0) == 0
    } else {
      framelessPiece = false
    }

    let outcome: StepOutcome
    if framelessPiece {
      outcome = .failed(StepFailure(
        kind: .noArtifact,
        summary: "The composite produced no video.",
        detail: result.standardError.isEmpty
          ? "FFmpeg exited successfully but the piece it wrote contains no frames."
          : result.standardError))
    } else if let failure = FailureInterpreter.interpret(
      exitStatus: result.status,
      standardError: result.standardError,
      artifactExists: produced)
    {
      outcome = .failed(failure)
    } else {
      // The Swift parent moves the finished file out; the helper only ever
      // writes inside our workspace.
      switch move(
        context.outputFile,
        toDestinationFor: step.kind,
        replacingExisting: job.replacesExistingFile)
      {
      case .notApplicable:
        outcome = .succeeded(artifact: context.outputFile)
      case .moved(let destination):
        outcome = .succeeded(artifact: destination)
      case .failed(let message):
        // A delivery failure is a step failure, even if the workspace artifact exists.
        outcome = .failed(StepFailure(
          kind: .moveFailed(message),
          summary: "Could not save the finished file.",
          detail: message))
      }
    }

    completeStep(id, outcome: outcome)
  }

  /// Recheck running state after awaits before completing or performing delivery side effects.
  private func isStillRunning(_ id: StepID) -> Bool {
    guard let location = locate(id) else { return false }
    return jobs[location.job].steps[location.step].status == .running
  }

  /// Clean up a late completion without replacing its already-final status, release pending job
  /// cleanup, and drive the queue.
  private func abandonAlreadyFinalizedStep(_ id: StepID) {
    running[id] = nil
    lastHeartbeatAt[id] = nil
    if let location = locate(id) {
      let job = jobs[location.job]
      journal.removeStep(job: job.id, step: id)
      if jobsAwaitingWorkspaceRemoval.contains(job.id) {
        removeJobWorkspaceIfSettled(job.id)
      }
    }
    tick()
  }

  /// Fold completion into jobs, clear the live helper, clean step/workspace state, and drive
  /// the queue.
  private func completeStep(_ id: StepID, outcome: StepOutcome) {
    running[id] = nil
    lastHeartbeatAt[id] = nil
    guard let location = locate(id) else { return }
    let jobID = jobs[location.job].id

    Scheduler.complete(id, with: outcome, in: &jobs)

    journal.removeStep(job: jobID, step: id)

    if jobs[location.job].status == .done {
      removeJobWorkspace(jobID)
    } else if jobsAwaitingWorkspaceRemoval.contains(jobID) {
      removeJobWorkspaceIfSettled(jobID)
    }

    tick()
  }

  // MARK: - Helpers

  private func removeObserver(_ id: UUID) {
    observers[id] = nil
  }

  private func publish() {
    for continuation in observers.values { continuation.yield(jobs) }
  }

  /// Debounced so a chatty render does not rewrite the queue file hundreds of
  /// times a second.
  private func scheduleSave() {
    saveTask?.cancel()
    saveTask = Task { [jobs, store = configuration.store] in
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      try? store.save(jobs)
    }
  }

  private func locate(_ id: StepID) -> (job: Int, step: Int)? {
    for (jobIndex, job) in jobs.enumerated() {
      if let stepIndex = job.steps.firstIndex(where: { $0.id == id }) {
        return (jobIndex, stepIndex)
      }
    }
    return nil
  }

  /// Defer workspace removal until all job helpers leave running; finish/completeStep retry
  /// cleanup after the last writer stops. Clear the pending entry on every non-deferred exit.
  private func removeJobWorkspaceIfSettled(_ id: JobID) {
    guard let job = jobs.first(where: { $0.id == id }) else {
      jobsAwaitingWorkspaceRemoval.remove(id)
      journal.removeJob(id)
      return
    }
    guard !job.steps.contains(where: { running[$0.id] != nil }) else {
      jobsAwaitingWorkspaceRemoval.insert(id)
      return
    }
    removeJobWorkspace(id)
    jobsAwaitingWorkspaceRemoval.remove(id)
  }

  /// Remove workspaces only for completed jobs, clearing intermediate artifact references in
  /// the same actor turn. Preserve delivered paths. Unfinished jobs keep successful
  /// intermediates for retry until the next startup sweep.
  private func removeJobWorkspace(_ id: JobID) {
    guard let index = jobs.firstIndex(where: { $0.id == id }) else {
      journal.removeJob(id)
      return
    }

    guard jobs[index].status == .done else {
      let isClaimed = jobs[index].steps.contains { step in
        guard step.status == .done, let artifact = step.artifact else { return false }
        return configuration.workspace.contains(artifact, ofJob: id)
      }
      guard !isClaimed else { return }
      journal.removeJob(id)
      return
    }

    // Check retention separately from Workspace.contains, which intentionally covers only
    // disposable job workspaces.
    var retained = configuration.workspace.resumeDirectory(id).standardizedFileURL.path
    if !retained.hasSuffix("/") { retained += "/" }

    for stepIndex in jobs[index].steps.indices {
      guard let artifact = jobs[index].steps[stepIndex].artifact else { continue }
      guard configuration.workspace.contains(artifact, ofJob: id)
              || artifact.standardizedFileURL.path.hasPrefix(retained)
      else { continue }
      jobs[index].steps[stepIndex].artifact = nil
    }
    journal.removeJob(id)

    // Remove retention only after whole-job success, following artifact-claim clearing in the
    // same actor turn. Cancelled jobs keep pieces for resume; Reconciler skips done jobs and
    // cannot repair stale claims later.
    journal.removeResumable(id)
  }

  /// Require an existing non-empty artifact; opening an output before cancellation can leave a
  /// zero-byte file. Nonisolated for Reconciler's synchronous check.
  private nonisolated static func isUsableArtifact(_ url: URL) -> Bool {
    guard
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true,
      let size = values.fileSize
    else { return false }
    return size > 0
  }

  /// Retained bytes reclaimed by dismissing the job; see docs/design/resume.md §8.
  public func retainedBytes(forJob id: JobID) -> Int {
    ledger.retainedBytes(forJob: id)
  }

  /// Return composite retention pieces and their directory, never the disposable job workspace.
  /// The directory is the reveal fallback before any piece exists.
  public func retainedFileURLs(forJob id: JobID) -> (directory: URL, pieces: [URL]) {
    ledger.retainedFileURLs(forJob: id)
  }

  /// Reveal existing retention first, otherwise an existing delivered assemble artifact,
  /// otherwise nil. Shared by menu enablement and activation.
  public func revealTarget(forJob id: JobID) -> RevealTarget? {
    let (directory, pieces) = retainedFileURLs(forJob: id)
    if !pieces.isEmpty || FileManager.default.fileExists(atPath: directory.path) {
      return .retained(directory: directory, pieces: pieces)
    }
    // Use assemble's artifact, not the first delivered file, which could be a separately
    // delivered chat file.
    guard
      let job = jobs.first(where: { $0.id == id }),
      let assemble = job.steps.first(where: {
        if case .assemble = $0.kind { return true }
        return false
      }),
      let delivered = assemble.deliveredArtifact,
      // Recheck existence because delivered files can be moved or deleted.
      FileManager.default.fileExists(atPath: delivered.path)
    else { return nil }
    return .delivered(delivered)
  }

  /// Synchronous context construction, callable without actor hopping; see
  /// StepContextBuilder.make.
  nonisolated func makeContext(job: Job, step: Step) throws -> StepContext {
    try contexts.make(job: job, step: step)
  }

  /// Deliver through StepKind.deliveryDestination; distinguish no destination from a failed
  /// move. Only replacingExisting authorizes overwrite. Otherwise use an available name and
  /// retry moveItem collisions without replacing, returning the actual delivered path.
  private func move(
    _ file: URL,
    toDestinationFor kind: StepKind,
    replacingExisting: Bool)
    -> MoveOutcome
  {
    guard let destination = kind.deliveryDestination else { return .notApplicable }

    do {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true)

      guard replacingExisting else {
        return .moved(try Delivery.moveWithoutReplacing(file, to: destination))
      }

      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
      } else {
        try FileManager.default.moveItem(at: file, to: destination)
      }
      return .moved(destination)
    } catch {
      return .failed("\(error)")
    }
  }
}
