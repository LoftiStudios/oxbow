import Foundation

/// What the composite step's Finder-reveal item should show. See
/// `QueueEngine.revealTarget(forJob:)` for how this is decided.
public enum RevealTarget: Equatable, Sendable {
  /// Select the pieces themselves where there are any; fall back to the
  /// (always-created once the composite step starts) retention directory for
  /// the gap between the step starting and its first fragment landing on
  /// disk.
  case retained(directory: URL, pieces: [URL])
  /// The retention area is gone and the job delivered — reveal what it
  /// actually produced instead of a directory that no longer exists.
  case delivered(URL)
}

/// Owns queue state and performs every side effect.
///
/// The scheduling rules live in `Scheduler` as pure functions, so this type is
/// mostly plumbing: admit, launch, fold the result back in, repeat.
public actor QueueEngine {

  public struct Configuration: Sendable {
    public var helperExecutable: URL
    public var ffmpegPath: URL
    public var workspace: Workspace
    /// - Important: `store.fileURL` must **not** live under `workspace.root`.
    ///   The queue is the app's own data; `workspace.root` is a cache
    ///   directory that `start()` sweeps on every launch and that the OS is
    ///   free to purge behind our back. A queue file nested inside it would
    ///   be lost to either.
    public var store: QueueStore
    public var makeProcess: @Sendable () -> HelperProcessing

    public init(
      helperExecutable: URL,
      ffmpegPath: URL,
      workspace: Workspace,
      store: QueueStore,
      makeProcess: @escaping @Sendable () -> HelperProcessing)
    {
      self.helperExecutable = helperExecutable
      self.ffmpegPath = ffmpegPath
      self.workspace = workspace
      self.store = store
      self.makeProcess = makeProcess
    }
  }

  /// Where a step's finished output ends up on success.
  private enum MoveOutcome {
    /// The step has no destination outside the workspace — its output stays
    /// where it is, as an intermediate for a later step to consume.
    case notApplicable
    case moved(URL)
    /// The destination write itself failed (full disk, unwritable volume,
    /// permissions, …). This must never be treated the same as
    /// `.notApplicable` — that would report a file that was never actually
    /// saved as a successfully completed step.
    case failed(String)
  }

  private let configuration: Configuration
  private var jobs: [Job] = []
  /// The live helper for each in-flight step, keyed by step. Only the helper
  /// is kept: the unstructured `Task` that drives it is deliberately not
  /// retained, because cancelling that task would not stop the child process
  /// — `HelperProcessing.cancel()` is the only thing that does.
  private var running: [StepID: HelperProcessing] = [:]
  /// Last time `heartbeat` wrote a line for a step — see its doc comment.
  private var lastHeartbeatAt: [StepID: ContinuousClock.Instant] = [:]
  private var observers: [UUID: AsyncStream<[Job]>.Continuation] = [:]
  private var saveTask: Task<Void, Never>?
  /// Jobs whose workspace a `cancel(job:)` wants removed, but that still had
  /// a step running when the kill signals were sent. `finish` clears one out
  /// once the last such step actually stops. See `removeJobWorkspaceIfSettled`.
  private var jobsAwaitingWorkspaceRemoval: Set<JobID> = []
  /// Set for good once `shutDown()` starts. From that moment the engine admits
  /// nothing new and folds no outcome back in — see `shutDown()` for why the
  /// results the kills produce must not be recorded.
  private var isShuttingDown = false

  public init(configuration: Configuration) {
    self.configuration = configuration
  }

  // MARK: - Public surface

  public var currentJobs: [Job] { jobs }

  /// True when nothing is running and nothing further can be admitted.
  public var isIdle: Bool {
    running.isEmpty && Scheduler.admissible(jobs: jobs, running: []).isEmpty
  }

  /// A method rather than a computed property: the `AsyncStream` builder
  /// closure captures and mutates `observers`, which strict concurrency
  /// rejects when it is expressed as a getter. `AsyncStream.makeStream()`
  /// sidesteps that by handing back the continuation directly, so the
  /// mutation happens in plain actor-isolated code instead of inside an
  /// escaping closure.
  ///
  /// `.bufferingNewest(1)` rather than the unbounded default: every element
  /// is a complete `[Job]`, and a render publishes one per status line —
  /// ~400 of them. A consumer replaces its whole array from each snapshot, so
  /// a superseded one carries no information and only costs memory.
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

  /// Sweeps the workspace, loads the queue, reconciles it, and starts work.
  ///
  /// The sweep is unconditional: nothing on disk can ever be resumed, so there
  /// is no case to reason about and no way for a power loss to leak disk.
  public func start() async throws {
    configuration.workspace.removeAll()

    let loaded = try configuration.store.load()
    jobs = Reconciler.reconcile(loaded) { Self.isUsableArtifact($0) }

    removeOrphanedResumeDirectories()

    tick()
  }

  /// Sweeps `resumeRoot` for a retention directory that names no job the
  /// queue just loaded — the one way one can exist, since every path that
  /// creates one (`prepareResume`, reached only from `makeContext` for a job
  /// already in `jobs`) is tied to a real job id. A lost or corrupted queue
  /// store is the only route to an orphan: without this, that directory
  /// would be both unreachable (nothing in the UI names it) and unshowable
  /// (`retainedBytes(forJob:)` needs a `JobID` nothing has any more) forever,
  /// since `removeAll()` deliberately does not reach `resumeRoot`.
  ///
  /// **Not the same sweep as `removeAll()`.** That one is unconditional
  /// because `jobs/` can never hold anything reusable; this one is
  /// conditional on purpose — a cancelled job still in the queue keeps its
  /// retained pieces (docs/design/resume.md §8), so only a directory whose
  /// name matches *no* loaded job, whatever that job's status, is removed.
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

  /// The tail of a step's captured helper output, or nil if it has none.
  ///
  /// Read through the engine rather than handing the UI a file path: the
  /// workspace layout is the engine's business, and a step's log is deleted
  /// with its job's workspace, so a URL handed out earlier could point at
  /// nothing by the time a view got round to reading it.
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
    // Record the terminal status — and stop admitting or blocking on it —
    // before awaiting the kill, not after. A real helper can take up to ~2s
    // to actually die; `finish` may run for this step at any point during
    // that window, and by the time it does, the status here must already be
    // `.cancelled` so `finish` bails instead of overwriting it with
    // `.failed(signalled(...))`.
    Scheduler.cancel(id, in: &jobs)
    tick()

    await running[id]?.cancel()
  }

  public func cancel(job id: JobID) async {
    guard let job = jobs.first(where: { $0.id == id }) else { return }

    // Same reasoning as `cancel(step:)`: record every unfinished step as
    // cancelled before awaiting any kill, so `finish` never races the status
    // write for any of them.
    Scheduler.cancel(job: id, in: &jobs)
    tick()

    let processes = job.steps.compactMap { running[$0.id] }

    // Concurrently, not one at a time: each `HelperProcess.cancel()` carries
    // its own ~2s grace period, so cancelling a three-step job serially could
    // take up to 6s instead of 2s.
    await withTaskGroup(of: Void.self) { group in
      for process in processes {
        group.addTask { await process.cancel() }
      }
    }

    // A helper that ignored SIGTERM can still be alive (and writing) here —
    // `removeJobWorkspaceIfSettled` only deletes once nothing is running.
    removeJobWorkspaceIfSettled(id)

    // Removal can clear a step's artifact, so republish and re-save rather
    // than leaving observers and the queue file holding the pre-removal view.
    tick()
  }

  /// Forgets these jobs entirely: out of the queue, out of the queue file, and
  /// their workspaces off disk.
  ///
  /// **Running jobs are cancelled first, never merely dropped.** Removing the
  /// row without signalling the helper would leave `TwitchDownloaderCLI` and
  /// the FFmpeg it spawned alive, reparented to `launchd`, still writing into a
  /// job workspace this call then deletes — the same orphaning that
  /// `shutDown()` exists to prevent, reached by a different door. Whether to
  /// warn the user before doing that is the UI's business; by the time a
  /// removal arrives here the decision has been made.
  ///
  /// **What is never removed is the file the user asked for.** A delivered
  /// artifact lives at a destination they chose, outside our workspace;
  /// clearing a row is housekeeping on our own queue and nothing more.
  ///
  /// Takes a set because removal is a selection-shaped action — the UI's
  /// Delete key acts on however many rows are selected, and doing that as N
  /// separate calls would publish N snapshots and re-save N times.
  public func remove(jobs ids: Set<JobID>) async {
    // Dismissing a job is how a user reclaims retained pieces — retention is
    // user-cleared for now, docs/design/resume.md §8 — so this runs
    // unconditionally, ahead of the `doomed` lookup below, rather than only
    // for a job still tracked here.
    for id in ids { removeResumableFiles(id) }

    let doomed = jobs.filter { ids.contains($0.id) }
    guard !doomed.isEmpty else { return }

    // Cancel every one that is live before touching the queue, and
    // concurrently: each `HelperProcess.cancel()` carries its own ~2s SIGTERM
    // grace period, so serialising them would multiply the wait by the number
    // of running steps removed.
    let processes = doomed.flatMap { job in job.steps.compactMap { running[$0.id] } }
    if !processes.isEmpty {
      for job in doomed { Scheduler.cancel(job: job.id, in: &self.jobs) }
      await withTaskGroup(of: Void.self) { group in
        for process in processes {
          group.addTask { await process.cancel() }
        }
      }
    }

    // Drop the `running` entries here rather than waiting for each cancelled
    // helper's completion callback. That callback fires whenever the SIGTERM
    // actually lands, and until it does the scheduler still counts the step
    // against its resource class — so a removal could leave the next queued
    // download unable to start, for a job that no longer exists. `completeStep`
    // arriving later is harmless: it clears an already-absent key and then
    // early-returns, because `locate` can no longer find the step.
    for job in doomed {
      for step in job.steps { running[step.id] = nil }
    }

    self.jobs.removeAll { ids.contains($0.id) }
    for id in ids { removeJobWorkspaceFiles(id) }

    // Publish and save, in that order, so observers and the queue file agree —
    // and so a removal survives a quit that happens before the debounce fires.
    tick()
  }

  /// Kills every in-flight helper, then writes final state. Call on app
  /// termination and await it before letting the process exit.
  ///
  /// `flush()` alone is not enough to quit safely. `HelperProcessing.cancel()`
  /// is the only thing that signals a helper's process group, so an app that
  /// only flushed would exit leaving `TwitchDownloaderCLI` and the FFmpeg it
  /// spawned running — reparented to `launchd`, still writing into a job
  /// workspace that the next launch's `Workspace.removeAll()` sweep would then
  /// delete out from under them.
  ///
  /// **In-flight steps stay `.running` in the saved queue.** They are not
  /// marked `.cancelled`: the user did not cancel them, and `.cancelled` is a
  /// status they can be retried out of but which claims an intent nobody had.
  /// Leaving them `.running` is what lets `Reconciler` turn them into
  /// `.failed(.interrupted)` at the next launch, which is the design's model
  /// for interrupted work (docs/design/task-queue.md — interrupted work reuses
  /// `.failed(.interrupted)` rather than earning its own case). That is also
  /// why `isShuttingDown` has to suppress step completion: killing a helper
  /// makes its `run` return `.signalled(SIGTERM)`, and folding that in would
  /// persist "crashed" — and would race the final save for which of the two
  /// statuses the queue file ends up holding.
  ///
  /// Cancelling concurrently is not an optimisation. Each
  /// `HelperProcess.cancel()` carries its own ~2s SIGTERM grace period, so
  /// signalling serially would add two seconds to the quit for every running
  /// step. Concurrently, the whole quit is bounded by one grace period.
  public func shutDown() async {
    isShuttingDown = true

    let processes = Array(running.values)
    await withTaskGroup(of: Void.self) { group in
      for process in processes {
        group.addTask { await process.cancel() }
      }
    }

    await flush()
  }

  /// Writes any pending state immediately. Not the app-termination entry
  /// point on its own — `shutDown()` is, and calls this last. Flushing
  /// without killing the helpers first is what orphaned them.
  public func flush() async {
    // Loop rather than a single check-and-await: awaiting a task releases
    // the actor, and a `tick()` landing in that window can install a fresh
    // `saveTask` before this resumes. Clearing `saveTask` to nil *before*
    // each await — not after — means a task installed during that window
    // survives into the next loop iteration instead of being silently
    // dropped uncancelled, where it would still fire ~500ms later and write
    // an older snapshot than the "final" save below.
    while let pending = saveTask {
      saveTask = nil
      pending.cancel()
      await pending.value
    }
    try? configuration.store.save(jobs)
  }

  // MARK: - The single drive point

  /// Admits what it can and launches it. EVERY mutation ends here, so there is
  /// never a question of who was supposed to kick the queue.
  private func tick() {
    // Nothing new may start once the quit is under way. The steps still in
    // `running` are being killed, not waited on, so admitting against them
    // would spawn a helper the app is about to walk out on.
    if !isShuttingDown {
      for id in Scheduler.admissible(jobs: jobs, running: Set(running.keys)) {
        launch(id)
      }
    }
    publish()
    scheduleSave()
  }

  private func launch(_ id: StepID) {
    guard let location = locate(id) else { return }
    let job = jobs[location.job]
    let step = job.steps[location.step]

    // `tick()` iterates a snapshot from `Scheduler.admissible`. A synchronous
    // failure below (`makeContext` throwing) re-enters `tick()` via
    // `completeStep`, which can already have launched a later step from that
    // same snapshot. This guard stops the outer loop from launching that
    // step a second time when it gets there.
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

    jobs[location.job].steps[location.step].status = .running

    // A fresh instance every launch: `HelperProcess` is documented single-use,
    // its `isCancelled` flag never resets, so reusing one across steps would
    // have every step after the first killed immediately.
    let process = configuration.makeProcess()

    // A composite runs FFmpeg directly rather than the C# helper, so both the
    // executable and the stdout dialect follow the step kind.
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
          // Status lines drive the progress bar and arrive by the hundreds.
          // Writing every one to the log would bury the handful of lines
          // that actually say what a step was doing when it stopped, so
          // `heartbeat` throttles this to a periodic summary instead.
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
      // `process.run` never produced a `RunResult` at all — there is no exit
      // status to interpret, so this reports the honest reason directly
      // instead of routing a fabricated `.exited(-1)` through
      // `FailureInterpreter`, which would surface as a meaningless
      // "exited with code -1" to the user.
      //
      // Both of `finish`'s guards apply here too, for the same reasons: a
      // quit must leave the step `.running` for the reconciler, and this is
      // reached after an `await`, so a cancellation may already have
      // finalized this step (e.g. `ProcessSpawner.spawn` failing while a
      // `cancel(step:)` for it is in flight).
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

  /// One line per `heartbeatInterval`, so a step that "feels stalled" has a
  /// timestamped trail of what it actually reported — phase, fraction, and
  /// (composite only) FFmpeg's own `speed=`, which is what tells "genuinely
  /// slow" apart from "stuck" without reaching for Activity Monitor. Anything
  /// finer than this belongs in the progress bar, not the transcript — see
  /// the comment where this is called.
  private func heartbeat(_ id: StepID, _ progress: StepProgress, log: StepLog?) async {
    guard let log else { return }

    // No line for the *first* status update a step ever reports: that only
    // says "it started," which the row already shows the instant it goes
    // `.running`. Recording the sighting without logging it is what makes a
    // step that finishes in under `heartbeatInterval` produce no heartbeat
    // lines at all — preserving `statusLinesAreNotWrittenToTheLog` for the
    // common case, while a step that runs long enough to feel stalled gets
    // its periodic trail.
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
    // Checked first, ahead of everything: `shutDown()` signalled this helper,
    // so `result` is our own kill reported back, not an outcome of the work.
    // Recording it would persist `.failed(.signalled(SIGTERM))` — "crashed" —
    // where the step must stay `.running` for `Reconciler` to read as
    // `.failed(.interrupted)` at the next launch. See `shutDown()`.
    //
    // Returns bare rather than routing through `abandonAlreadyFinalizedStep`:
    // the step is not finalized, and that path would clear `running[id]`,
    // delete the step's directory, and `tick()` — none of which this wants.
    guard !isShuttingDown else { return }

    // Checked *before* any side-effecting work below (in particular, before
    // `move`): cancelled (or otherwise finalized) while this was in flight,
    // the cancellation path already recorded the terminal status and blocked
    // dependents. Overwriting it here — or moving a file that finished
    // writing only after the user cancelled it — would both be wrong, and
    // checking only at the point of folding the outcome in (as `completeStep`
    // does) would be too late: the move would already have happened.
    guard isStillRunning(id) else {
      abandonAlreadyFinalizedStep(id)
      return
    }

    guard let location = locate(id) else {
      // Can't actually happen given the check above just ran on this same
      // actor turn with no intervening suspension, but keeps this total.
      running[id] = nil
      lastHeartbeatAt[id] = nil
      return
    }
    let job = jobs[location.job]
    let step = job.steps[location.step]

    // Success is the artifact, not the exit code: the CLI's `Main` returns
    // void, so nothing sets a meaningful exit status on its own.
    let produced = Self.isUsableArtifact(context.outputFile)

    let outcome: StepOutcome
    if let failure = FailureInterpreter.interpret(
      exitStatus: result.status,
      standardError: result.standardError,
      artifactExists: produced)
    {
      outcome = .failed(failure)
    } else {
      // The Swift parent moves the finished file out; the helper only ever
      // writes inside our workspace.
      switch move(context.outputFile, toDestinationFor: step.kind) {
      case .notApplicable:
        outcome = .succeeded(artifact: context.outputFile)
      case .moved(let destination):
        outcome = .succeeded(artifact: destination)
      case .failed(let message):
        // The step did its job — the artifact existed — but we failed to get
        // it out to the user, so this must not read as success: nothing else
        // would ever surface the problem, and `finish`'s own cleanup would
        // otherwise delete the only copy of the file.
        outcome = .failed(StepFailure(
          kind: .moveFailed(message),
          summary: "Could not save the finished file.",
          detail: message))
      }
    }

    completeStep(id, outcome: outcome)
  }

  /// True if this step is still `.running` — i.e. nothing has already
  /// finalized it (a cancellation, most likely) while the caller was
  /// suspended on an `await`. Every path that is about to complete a step,
  /// or perform a side effect gated on the step still being in progress
  /// (moving the finished file), must check this first.
  private func isStillRunning(_ id: StepID) -> Bool {
    guard let location = locate(id) else { return false }
    return jobs[location.job].steps[location.step].status == .running
  }

  /// Tears down a step that turned out to already be finalized by the time
  /// its completion reached the actor: clears `running[id]`, removes the
  /// step's own workspace directory, releases a job-level cancel that may
  /// have been waiting on it, and drives the queue forward. Never calls
  /// `Scheduler.complete` — the status is already final and must not be
  /// overwritten.
  private func abandonAlreadyFinalizedStep(_ id: StepID) {
    running[id] = nil
    lastHeartbeatAt[id] = nil
    if let location = locate(id) {
      let job = jobs[location.job]
      removeStepWorkspaceFiles(job: job.id, step: id)
      if jobsAwaitingWorkspaceRemoval.contains(job.id) {
        removeJobWorkspaceIfSettled(job.id)
      }
    }
    tick()
  }

  /// The shared tail of every step completion: fold the outcome into `jobs`,
  /// tear down the step's workspace, finish a job-level cancel that was
  /// waiting on this step, and drive the queue forward.
  ///
  /// `running[id]` is always cleared here, on every path that reaches it —
  /// including `finish`'s own early-return above — so `isIdle` can never
  /// wedge on a step that finished, however it finished.
  private func completeStep(_ id: StepID, outcome: StepOutcome) {
    running[id] = nil
    lastHeartbeatAt[id] = nil
    guard let location = locate(id) else { return }
    let jobID = jobs[location.job].id

    Scheduler.complete(id, with: outcome, in: &jobs)

    removeStepWorkspaceFiles(job: jobID, step: id)

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

  // MARK: - Teardown reporting
  //
  // `Workspace`'s removal methods no longer discard what they fail to
  // remove — see their doc comments. These three wrappers are the only
  // callers of those methods anywhere in this file, so every workspace
  // teardown is guaranteed to have somewhere to report a failure, rather
  // than that being a discipline each call site has to remember on its own.
  // That is the fix for the actual incident this exists to prevent: an
  // 8.66 GB video that outlived its job's teardown with nothing anywhere
  // recording that the removal had failed.

  /// Tears down a step's own working directory and reports anything left
  /// behind in that step's transcript — see `recordStepTeardownFailure`.
  private nonisolated func removeStepWorkspaceFiles(job: JobID, step: StepID) {
    recordStepTeardownFailure(
      configuration.workspace.removeStep(job: job, step: step), job: job, step: step)
  }

  /// Tears down a job's whole workspace and reports anything left behind —
  /// see `recordTeardownFailure`.
  private nonisolated func removeJobWorkspaceFiles(_ id: JobID) {
    recordTeardownFailure(
      configuration.workspace.removeJob(id), context: "job \(id.rawValue.uuidString): workspace")
  }

  /// Tears down a job's retained-pieces area and reports anything left
  /// behind — see `recordTeardownFailure`.
  private nonisolated func removeResumableFiles(_ id: JobID) {
    recordTeardownFailure(
      configuration.workspace.removeResumable(id),
      context: "job \(id.rawValue.uuidString): resumable area")
  }

  /// Writes a step-level teardown failure into that step's own `StepLog` —
  /// the file already meant to hold "why did this go wrong" for exactly
  /// this step, and, unlike a job-level failure, one that is still standing
  /// when this runs: `removeStep` only ever touches the step's own working
  /// directory (`stepDirectory`), never `logs/`. That directory — and this
  /// step's slice of it — survives until the whole job's workspace goes
  /// with `removeJob`, so the row someone would already open to ask what
  /// went wrong is where this shows up.
  ///
  /// Fire-and-forget: `StepLog.append` is `async`, actor-isolated to
  /// `StepLog` itself rather than to `QueueEngine`, and every call site here
  /// (`completeStep`, `abandonAlreadyFinalizedStep`) is a synchronous
  /// teardown path that must not become `async` just to report a failure
  /// that changes no queue state. Nothing here races anything that matters:
  /// `removeStep` never touches this file, and the one interleaving that
  /// could happen — a job-level teardown deleting `logs/` before this write
  /// lands — just recreates a single-entry `logs/` for a job that is
  /// already gone, which is itself more evidence, not corruption.
  private nonisolated func recordStepTeardownFailure(_ failed: [URL], job: JobID, step: StepID) {
    guard !failed.isEmpty else { return }
    let workspace = configuration.workspace
    Task {
      let log = StepLog(fileURL: workspace.logFile(job: job, step: step))
      await log.append("[teardown] could not remove: " + failed.map(\.path).joined(separator: ", "))
      await log.close()
    }
  }

  /// Records a job- or resumable-area teardown failure, or a failure
  /// dropping assemble's spent inputs, somewhere it survives being
  /// reported. Those three have no per-step home the way a step-level
  /// failure does: `removeJob` takes the job's own `logs/` directory down
  /// with it as part of what it tears down, and the assemble-time cleanup
  /// runs once per job rather than once per step. This writes instead to
  /// `Workspace.teardownFailureLog`, a small file that sits beside `jobs/`
  /// and `resume/` — neither `removeJob` nor the launch sweep
  /// (`removeAll()`, scoped to `jobsRoot`) can ever reach it, so it
  /// outlives every failure it records and accumulates across launches.
  ///
  /// `nonisolated`: reached from `resumePoint` and `makeContext`, both
  /// nonisolated because they touch nothing but `configuration`. This does
  /// the same — plain synchronous file I/O against an immutable path — so
  /// it can be too, and actor-isolated callers reach it exactly like any
  /// other nonisolated method, no `await` required.
  private nonisolated func recordTeardownFailure(_ failed: [URL], context: String) {
    guard !failed.isEmpty else { return }

    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(timestamp) \(context) — could not remove: "
      + failed.map(\.path).joined(separator: ", ") + "\n"
    guard let data = line.data(using: .utf8) else { return }

    // `FileHandle.write(_:)` (no `contentsOf:`) can raise an uncaught
    // Objective-C exception on a genuine write failure rather than
    // returning a Swift error — exactly the kind of failure a full disk
    // would produce, which is also a plausible companion to a teardown
    // failure. `write(contentsOf:)` is the throwing form, so a failure here
    // is just another swallowed `try?` rather than a crash compounding the
    // problem this method exists to report.
    let log = configuration.workspace.teardownFailureLog
    if let handle = try? FileHandle(forWritingTo: log) {
      defer { try? handle.close() }
      // A failed seek must not fall through to the write below: opening for
      // writing does not itself seek, so that write would land at offset 0
      // and overwrite every entry already accumulated here — destroying the
      // history this file exists to keep, in exchange for recording the one
      // failure that triggered it.
      guard (try? handle.seekToEnd()) != nil else { return }
      try? handle.write(contentsOf: data)
    } else if !FileManager.default.fileExists(atPath: log.path) {
      // Reached only when the file genuinely does not exist yet.
      // `FileHandle(forWritingTo:)` can also fail to open a file that *does*
      // exist — a permissions problem, say — and `createFile(atPath:contents:)`
      // truncates, so falling through to it unconditionally would silently
      // wipe an existing log the moment opening it started failing for any
      // reason, not only the reason this branch is for.
      try? FileManager.default.createDirectory(
        at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: log.path, contents: data)
      return
    } else {
      return
    }

    compactTeardownFailureLogIfNeeded()
  }

  /// Bounds `teardownFailureLog` the way `StepLog` bounds its own file — see
  /// its doc comment — because this file has the same problem and no
  /// dedicated owner to solve it a different way: it sits outside the launch
  /// sweep (`Workspace.removeAll()` is scoped to `jobsRoot`) and nothing else
  /// reads or rotates it, so an unbounded accumulation across launches is not
  /// a policy, just an oversight.
  ///
  /// Unlike `StepLog`, there is no persistent actor here to track a running
  /// byte count between writes — this is a plain nonisolated function called
  /// once per failure — so this checks the file's actual size instead. A
  /// failed teardown is rare enough that re-reading a capped-size file on
  /// each one costs nothing that matters.
  private nonisolated func compactTeardownFailureLogIfNeeded() {
    let log = configuration.workspace.teardownFailureLog
    let cap = StepLog.defaultMaxBytes

    // Compact only when meaningfully over, not the instant the cap is
    // crossed — same reasoning as `StepLog.append`: rewriting the file on
    // every single write would be needless O(n^2) I/O for what is meant to
    // be an occasional, low-volume file.
    guard
      let data = try? Data(contentsOf: log),
      data.count > cap + cap / 2
    else { return }

    // Drops whole lines, never a byte offset, for the same reason
    // `StepLog.compact()` does: a byte cut could leave a mangled first entry
    // that reads as corruption rather than as "the older history was
    // trimmed".
    let text = String(decoding: data, as: UTF8.self)
    var kept = Substring(text)
    while kept.utf8.count > cap, let newline = kept.firstIndex(of: "\n") {
      kept = kept[kept.index(after: newline)...]
    }
    try? Data(kept.utf8).write(to: log, options: .atomic)
  }

  /// Removes a job's workspace once nothing belonging to it is still
  /// `running`. A helper can outlive its kill signal by up to ~2s, so at the
  /// moment `cancel(job:)`'s kills return there may still be a process
  /// mid-write into this directory. If so, this defers by recording the job
  /// in `jobsAwaitingWorkspaceRemoval`; `completeStep`/`finish` call back in
  /// here the moment that last step actually clears `running`.
  ///
  /// Every exit other than the deferral resolves the pending entry, so it can
  /// never be left behind to fire against a later, unrelated completion.
  private func removeJobWorkspaceIfSettled(_ id: JobID) {
    guard let job = jobs.first(where: { $0.id == id }) else {
      jobsAwaitingWorkspaceRemoval.remove(id)
      removeJobWorkspaceFiles(id)
      return
    }
    guard !job.steps.contains(where: { running[$0.id] != nil }) else {
      jobsAwaitingWorkspaceRemoval.insert(id)
      return
    }
    removeJobWorkspace(id)
    jobsAwaitingWorkspaceRemoval.remove(id)
  }

  /// Deletes a job's workspace while preserving the invariant that **a step is
  /// `.done` only if the artifact it records still exists**.
  ///
  /// `jobs/<id>/` holds `artifacts/`, the intermediates handed from one step to
  /// the next, so deleting it can destroy a file an earlier `.done` step still
  /// points at. Two cases, and only two:
  ///
  /// 1. The job is `.done`. It is finished and can never run again, so the
  ///    intermediates are genuinely disposable — but the claims on them go in
  ///    the same actor turn as the files, leaving no step pointing at
  ///    something that is gone. Steps whose artifact was moved out to the
  ///    user's chosen location keep theirs; those live outside the workspace.
  ///    (`Reconciler` will not requeue a `.done` job's steps, so nothing
  ///    resurrects what is dropped here.)
  /// 2. The job is not finished — a cancel, most often. A later step may still
  ///    be retried, and an earlier `.done` step's intermediate is exactly the
  ///    input that retry needs, so the directory stays. One chat file per
  ///    cancelled job is bounded, and `Workspace.removeAll()` sweeps it at the
  ///    next launch anyway.
  private func removeJobWorkspace(_ id: JobID) {
    guard let index = jobs.firstIndex(where: { $0.id == id }) else {
      removeJobWorkspaceFiles(id)
      return
    }

    guard jobs[index].status == .done else {
      let isClaimed = jobs[index].steps.contains { step in
        guard step.status == .done, let artifact = step.artifact else { return false }
        return configuration.workspace.contains(artifact, ofJob: id)
      }
      guard !isClaimed else { return }
      removeJobWorkspaceFiles(id)
      return
    }

    // A retained piece (the composite step's own artifact) lives under
    // `resumeDirectory`, not `jobDirectory` — `Workspace.contains` deliberately
    // does not recognise it (see its doc comment: a retained piece outlives
    // the job workspace by design), so the loop below cannot rely on
    // `contains` alone to find it. Checked here, in the caller, rather than
    // by widening `contains` itself, which would blur the one thing that
    // doc comment exists to keep separate.
    var retained = configuration.workspace.resumeDirectory(id).standardizedFileURL.path
    if !retained.hasSuffix("/") { retained += "/" }

    for stepIndex in jobs[index].steps.indices {
      guard let artifact = jobs[index].steps[stepIndex].artifact else { continue }
      guard configuration.workspace.contains(artifact, ofJob: id)
              || artifact.standardizedFileURL.path.hasPrefix(retained)
      else { continue }
      jobs[index].steps[stepIndex].artifact = nil
    }
    removeJobWorkspaceFiles(id)

    // Reached only on the genuinely-`.done` path above, never from the
    // not-done branch that can return early to preserve a cancelled job's
    // intermediates for a retry. A retained piece is exactly what that retry
    // would continue from, so clearing it there would defeat resume before
    // it ever got used. Delivered means done: the retained bytes have no
    // further use. docs/design/resume.md §8.
    //
    // Comes after the claim-clearing loop above, in the same actor turn:
    // the composite step's artifact is nilled there because it will be gone
    // the instant this runs, not because the file happens to be gone yet.
    // Reconciler will not get a second chance to notice — it short-circuits
    // for a `.done` job — so nothing here may leave a step pointing at a
    // piece this call is about to delete.
    removeResumableFiles(id)
  }

  /// Spec §1.5: a step succeeded iff its artifact exists **and is non-empty**.
  ///
  /// The exit code decides nothing — the CLI's `Main` returns void — so this
  /// is the entire success criterion, and existence alone is not it: a helper
  /// killed after opening its output file leaves a zero-byte file behind,
  /// which `fileExists` reads as a finished download and happily moves to the
  /// user's folder.
  ///
  /// `nonisolated` so `start()` can hand it to `Reconciler` as a plain
  /// function.
  private nonisolated static func isUsableArtifact(_ url: URL) -> Bool {
    guard
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true,
      let size = values.fileSize
    else { return false }
    return size > 0
  }

  /// How many times a composite may be continued before a retry starts over.
  ///
  /// Each resume adds an encode boundary, and a job that has failed this many
  /// times is reporting something that continuing will not fix. Accumulating
  /// pieces turns a persistent fault into a slowly degrading file instead of
  /// a clear failure. docs/design/resume.md §7.
  private static let maximumPieces = 4

  /// The pieces already on disk for a job, in order.
  private nonisolated func pieces(of job: JobID) -> [URL] {
    let directory = configuration.workspace.resumeDirectory(job)
    let contents = (try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)) ?? []
    return contents
      .filter { $0.lastPathComponent.hasPrefix("piece-") }
      .sorted { $0.lastPathComponent.compare(
        $1.lastPathComponent, options: .numeric) == .orderedAscending }
  }

  /// Bytes held in the retention area for a job.
  ///
  /// Surfaced on the row because retention is user-cleared: the space is
  /// reclaimed by dismissing the job, and a user who cannot see the cost will
  /// never connect the two. docs/design/resume.md §8.
  public func retainedBytes(forJob id: JobID) -> Int {
    pieces(of: id).reduce(0) { total, piece in
      total + (((try? FileManager.default
        .attributesOfItem(atPath: piece.path))?[.size] as? NSNumber)?.intValue ?? 0)
    }
  }

  /// Where the composite step's own Finder-reveal item points, and what to
  /// select there. docs/design/fragmented-output.md §6.
  ///
  /// Always the retention area, never the job workspace: the workspace also
  /// holds the downloaded video, the chat JSON, and the chat render, and
  /// revealing those alongside the composite's own working file is the bug
  /// this affordance exists to avoid. `directory` is `resumeDirectory(id)`
  /// itself, `prepareResume` creates it the moment the composite step starts,
  /// so it exists for every case the caller's enablement rule (§6: the combine
  /// has started) would ever call this for — used as the fallback selection
  /// when `pieces` is empty, e.g. the gap between the step starting and its
  /// first fragment landing on disk.
  public func retainedFileURLs(forJob id: JobID) -> (directory: URL, pieces: [URL]) {
    (configuration.workspace.resumeDirectory(id), pieces(of: id))
  }

  /// What the composite step's Finder-reveal item should show right now, in
  /// the order these are tried:
  ///
  /// 1. The retention area is still on disk — the ordinary case whenever a
  ///    composite has started and the job has not yet fully delivered
  ///    (`.retained`, exactly what `retainedFileURLs` already returns).
  /// 2. It is gone precisely *because* the job delivered — `removeJobWorkspace`
  ///    deletes it the moment the job reaches `.done` (docs/design/resume.md
  ///    §8) — so the useful answer is the file it actually delivered, the
  ///    `.assemble` step's own artifact, not a directory that no longer
  ///    exists (`.delivered`).
  /// 3. Neither: the composite has not started yet. There is nothing to
  ///    reveal, and the caller (`StepRow`) disables the item rather than
  ///    inventing something to select.
  ///
  /// One definition rather than two, because a caller checking whether the
  /// item should be enabled and the click that actually reveals something
  /// must never disagree about what "there is something here" means.
  public func revealTarget(forJob id: JobID) -> RevealTarget? {
    let (directory, pieces) = retainedFileURLs(forJob: id)
    if !pieces.isEmpty || FileManager.default.fileExists(atPath: directory.path) {
      return .retained(directory: directory, pieces: pieces)
    }
    // Pinned to the `.assemble` step specifically, not `job.deliveredFiles.first`
    // — today the two coincide only because the intake gives media, chat and
    // render steps no destination of their own and step order puts them
    // ahead of assemble in a composite job. The day a composite job also
    // delivers, say, its chat JSON, `.first` would silently start pointing
    // this row's "Show in Finder" at the wrong file.
    guard
      let job = jobs.first(where: { $0.id == id }),
      let assemble = job.steps.first(where: {
        if case .assemble = $0.kind { return true }
        return false
      }),
      let delivered = assemble.deliveredArtifact,
      // Rule 1 above checks the retention directory still exists before
      // trusting it; this rule owes the delivered file the same check —
      // moved or deleted after delivery, `assemble.artifact` still names it,
      // and without this the item would stay enabled pointing at nothing,
      // the defect `e61278f` fixed on the retention branch surviving here.
      FileManager.default.fileExists(atPath: delivered.path)
    else { return nil }
    return .delivered(delivered)
  }

  /// Repairs the last piece, counts what survived, and says where to resume.
  ///
  /// Returns `nil` for a first attempt and when the piece cap is hit — in the
  /// latter case the retained pieces are dropped first, so the caller starts
  /// from `piece-0` with a clean directory.
  private nonisolated func resumePoint(
    job: JobID, framerate: Int)
    -> (index: Int, from: Duration?)
  {
    let existing = pieces(of: job)
    guard !existing.isEmpty else { return (0, nil) }
    guard existing.count < Self.maximumPieces else {
      removeResumableFiles(job)
      return (0, nil)
    }

    // Only the last piece can be torn — earlier ones were completed before
    // the next began. Repair is a no-op on an untorn file.
    if let last = existing.last { _ = try? FragmentedMP4.repair(last) }

    // A piece that contributed zero frames is one FFmpeg opened (`ftyp` +
    // `moov`) but was killed before finishing a single fragment for — there
    // is nothing in it to resume from. Left on disk it would still count as
    // a real attempt: it burns a slot against `maximumPieces`, and
    // `.assemble`'s `pieces.txt` would list it as an empty segment in the
    // concat. Discarded outright rather than repaired — repair only fixes a
    // torn trailing fragment, and an absent one is not that.
    var survivors: [URL] = []
    var frames = 0
    for piece in existing {
      let count = (try? FragmentedMP4.index(of: piece))?.frameCount ?? 0
      if count > 0 {
        survivors.append(piece)
        frames += count
      } else {
        try? FileManager.default.removeItem(at: piece)
      }
    }
    guard frames > 0 else {
      removeResumableFiles(job)
      return (0, nil)
    }
    return (survivors.count, .seconds(Double(frames) / Double(framerate)))
  }

  /// Builds a step's `StepContext`: where it works, where it writes, and
  /// (for a composite) where it resumes from.
  ///
  /// `nonisolated` — and callable with no `await` — because it touches
  /// nothing but `configuration`, which is immutable and `Sendable`. That
  /// also happens to be what lets tests exercise it directly without hopping
  /// onto the actor.
  nonisolated func makeContext(job: Job, step: Step) throws -> StepContext {
    let stepDirectory = try configuration.workspace.prepareStep(job: job.id, step: step.id)
    let artifacts = try configuration.workspace.prepareArtifacts(job: job.id)

    // The CLI infers download type from the output file extension.
    let name: String = switch step.kind {
    case .downloadVideo: "video.mp4"
    case .downloadClip: "clip.mp4"
    case .downloadChat(let request): "chat.\(request.format.rawValue)"
    case .renderChat: "render.mp4"
    case .composite: "composite.mp4"
    case .assemble: "assemble.mp4"
    }

    // Order-preserving: `Step.dependsOn` is ordered and the argument builder
    // reads these positionally.
    let inputs = step.dependsOn.compactMap { dependency in
      job.steps.first { $0.id == dependency }?.artifact
    }

    // `compactMap` silently drops a missing artifact, which would otherwise
    // shift every later positional input down by one — a composite reading
    // its chat render as `input 0` because the video's artifact went missing.
    // That surfaces as a baffling FFmpeg error (wrong stream mapped, or a
    // filter given too few inputs) far from its real cause: a step ran with a
    // parent that was not actually `.done`, which should never happen given
    // `Scheduler.admissible`'s guard, but a future regression there should be
    // loud here rather than silently mis-wired.
    guard inputs.count == step.dependsOn.count else {
      throw StepWiringError(
        "step \(step.id) expected \(step.dependsOn.count) input artifact(s) "
          + "but only \(inputs.count) parent(s) had one")
    }

    if case .composite(let request) = step.kind {
      // `resumePoint` first: past the cap it removes the retained directory
      // entirely, and `prepareResume` recreates it — empty — right after, so
      // `directory` names a real, empty directory either way. Calling these
      // in the other order would hand back a piece path inside a directory
      // that no longer exists once the cap resets it.
      let resume = resumePoint(job: job.id, framerate: request.framerate)
      let directory = try configuration.workspace.prepareResume(job: job.id)

      // A resumed job re-downloads its source, and Twitch does not guarantee
      // it comes back the same: sections get muted for DMCA after the fact,
      // renditions get re-encoded, VODs get trimmed. Half a composite from
      // before such a change and half from after produces a file with a
      // discontinuity and no error anywhere — the encode succeeds, the join
      // succeeds, and the video is quietly wrong. Byte length plus duration
      // catches that: two real downloads of the same VOD were measured
      // byte-for-byte different but identical in both of these, so a mismatch
      // here means the source itself changed, not just re-encoding noise. See
      // docs/design/resume.md §7.
      let fingerprintFile = directory.appending(path: "source.json")
      let sourceVideo = inputs.first
      if let sourceVideo {
        let fresh = try SourceFingerprint.of(sourceVideo, duration: request.duration)
        if resume.from == nil {
          try? fresh.write(to: fingerprintFile)
        } else {
          // Fail closed, not open. A full disk is the likeliest reason the
          // composite failed at all, and also the likeliest reason
          // `source.json` itself failed to write on the first attempt or
          // fails to read back now — so "cannot verify" must refuse exactly
          // like "verified, and it disagrees" (§7: refuses rather than
          // repairs). Treating a missing or unreadable fingerprint as an
          // implicit match would resume unverified in precisely the
          // situation this check exists to catch.
          guard let recorded = try? SourceFingerprint.read(from: fingerprintFile) else {
            throw SourceChangedError(reason:
              "This download's earlier attempt could not be verified — its "
                + "recorded source fingerprint is missing or unreadable. Start it again.")
          }
          guard recorded.matches(fresh) else {
            throw SourceChangedError()
          }
        }
      }

      // "Exists and is non-empty" is not enough — a `SIGKILL` mid-write
      // leaves a non-empty file with no `moov`. `hasCompleteMoov` is the same
      // no-decode box walk `FragmentIndex` already uses for pieces, applied
      // to the one file on this path that is deliberately *not* fragmented.
      // Any I/O failure here (missing file, unreadable) is "not usable" —
      // the safe default, since the cost of a spurious rewrite is a cheap
      // stream copy, while treating a corrupt sidecar as usable is the exact
      // defect this fix closes. resume.md §4.
      let sidecarFile = directory.appending(path: "audio.m4a")
      let hasUsableSidecar = FileManager.default.fileExists(atPath: sidecarFile.path)
        && ((try? FragmentedMP4.hasCompleteMoov(at: sidecarFile)) ?? false)

      return StepContext(
        stepTempDirectory: stepDirectory,
        outputFile: directory.appending(path: "piece-\(resume.index).mp4"),
        ffmpegPath: configuration.ffmpegPath,
        inputArtifacts: inputs,
        resumeFrom: resume.from,
        hasUsableSidecar: hasUsableSidecar,
        log: StepLog(fileURL: configuration.workspace.logFile(job: job.id, step: step.id)))
    }

    if case .assemble = step.kind {
      // The concat demuxer reads a list file. Written here rather than in
      // ArgumentBuilder because that type is pure and does no I/O.
      let list = pieces(of: job.id)
        .map { "file '\($0.path)'" }
        .joined(separator: "\n") + "\n"
      try list.write(
        to: stepDirectory.appending(path: "pieces.txt"), atomically: true, encoding: .utf8)

      // The re-fetched video and chat render are both dead once the pieces
      // and the sidecar audio exist. Dropping them here rather than at job
      // end is what keeps the recovery peak near a normal run's — resume.md
      // §5. Scoped to this job's workspace so nothing outside it can be hit.
      let spent = job.steps.compactMap { step -> URL? in
        switch step.kind {
        case .downloadVideo, .downloadClip, .renderChat: step.artifact
        case .downloadChat, .composite, .assemble: nil
        }
      }
      let unremoved = spent
        .filter { configuration.workspace.contains($0, ofJob: job.id) }
        .compactMap { file -> URL? in
          do {
            try FileManager.default.removeItem(at: file)
            return nil
          } catch {
            return file
          }
        }
      recordTeardownFailure(
        unremoved, context: "job \(job.id.rawValue.uuidString): re-fetched inputs spent by assemble")

      // Assemble's single input artifact is the sidecar audio, not a parent's
      // output — everything else it needs is in the retention area and named
      // by convention. `ArgumentBuilder` stays pure by being handed the path.
      return StepContext(
        stepTempDirectory: stepDirectory,
        outputFile: artifacts.appending(path: name),
        ffmpegPath: configuration.ffmpegPath,
        inputArtifacts: [configuration.workspace
          .resumeDirectory(job.id).appending(path: "audio.m4a")],
        log: StepLog(fileURL: configuration.workspace.logFile(job: job.id, step: step.id)))
    }

    return StepContext(
      stepTempDirectory: stepDirectory,
      outputFile: artifacts.appending(path: name),
      ffmpegPath: configuration.ffmpegPath,
      inputArtifacts: inputs,
      log: StepLog(fileURL: configuration.workspace.logFile(job: job.id, step: step.id)))
  }

  /// Moves a finished step's output to its final destination.
  ///
  /// Distinguishes "this kind has no destination, keep it as an intermediate"
  /// from "the move itself failed" — collapsing those (e.g. via `?? file`)
  /// would report a move failure as success. `.failed` remains the only way
  /// `nil` can mean a problem, so the two cases must stay distinguishable.
  /// The destination itself is `StepKind.deliveryDestination` — see its doc
  /// comment for why `.composite` counts as having none despite
  /// `CompositeRequest` carrying its own `destination` field.
  private func move(_ file: URL, toDestinationFor kind: StepKind) -> MoveOutcome {
    guard let destination = kind.deliveryDestination else { return .notApplicable }

    do {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true)
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

/// Thrown when a resumed job's re-downloaded source no longer matches what
/// piece 0 was built from — or when that comparison could not be made at
/// all. See docs/design/resume.md §7.
struct SourceChangedError: Error {
  /// Set only when refusing because the fingerprint could not be read back,
  /// rather than because it was read and disagreed with the fresh one. The
  /// two need different words: "the source changed" overstates what is
  /// actually known when the fingerprint itself is the thing missing. `nil`
  /// falls back to the ordinary mismatch message at the catch site.
  let reason: String?

  init(reason: String? = nil) {
    self.reason = reason
  }
}

/// Thrown by `QueueEngine.makeContext` when a step's resolved input artifacts
/// are shorter than its `dependsOn`, so `launch` can report a wiring bug
/// distinctly from an ordinary working-directory failure.
private struct StepWiringError: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
