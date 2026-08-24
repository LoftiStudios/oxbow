import Foundation

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
    ///   `start()` unconditionally deletes the entire workspace root before
    ///   loading the store, so a queue file nested inside it would be wiped
    ///   out immediately before the read that is supposed to recover it.
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

  private struct RunningStep {
    let process: HelperProcessing
    let task: Task<Void, Never>
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
  private var running: [StepID: RunningStep] = [:]
  private var observers: [UUID: AsyncStream<[Job]>.Continuation] = [:]
  private var saveTask: Task<Void, Never>?
  /// Jobs whose workspace a `cancel(job:)` wants removed, but that still had
  /// a step running when the kill signals were sent. `finish` clears one out
  /// once the last such step actually stops. See `removeJobWorkspaceIfSettled`.
  private var jobsAwaitingWorkspaceRemoval: Set<JobID> = []

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
  public func makeSnapshots() -> AsyncStream<[Job]> {
    let (stream, continuation) = AsyncStream<[Job]>.makeStream()
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
    jobs = Reconciler.reconcile(loaded) { FileManager.default.fileExists(atPath: $0.path) }

    tick()
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

  public func cancel(step id: StepID) async {
    // Record the terminal status — and stop admitting or blocking on it —
    // before awaiting the kill, not after. A real helper can take up to ~2s
    // to actually die; `finish` may run for this step at any point during
    // that window, and by the time it does, the status here must already be
    // `.cancelled` so `finish` bails instead of overwriting it with
    // `.failed(signalled(...))`.
    Scheduler.cancel(id, in: &jobs)
    tick()

    await running[id]?.process.cancel()
  }

  public func cancel(job id: JobID) async {
    guard let job = jobs.first(where: { $0.id == id }) else { return }

    // Same reasoning as `cancel(step:)`: record every unfinished step as
    // cancelled before awaiting any kill, so `finish` never races the status
    // write for any of them.
    Scheduler.cancel(job: id, in: &jobs)
    tick()

    let processes = job.steps.compactMap { running[$0.id]?.process }

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
  }

  /// Writes any pending state immediately. Call on app termination.
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
    for id in Scheduler.admissible(jobs: jobs, running: Set(running.keys)) {
      launch(id)
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
    let launch = Launch(
      executable: configuration.helperExecutable,
      arguments: ArgumentBuilder.arguments(for: step.kind, context: context),
      workingDirectory: context.stepTempDirectory)

    let task = Task { [weak self] in
      guard let self else { return }
      await self.execute(id, process: process, launch: launch, context: context)
    }
    running[id] = RunningStep(process: process, task: task)
  }

  private func execute(
    _ id: StepID,
    process: HelperProcessing,
    launch: Launch,
    context: StepContext)
    async
  {
    do {
      let result = try await process.run(launch) { [weak self] line in
        guard case .status(let progress) = line else { return }
        await self?.updateProgress(id, progress)
      }
      finish(id, result: result, context: context)
    } catch {
      // `process.run` never produced a `RunResult` at all — there is no exit
      // status to interpret, so this reports the honest reason directly
      // instead of routing a fabricated `.exited(-1)` through
      // `FailureInterpreter`, which would surface as a meaningless
      // "exited with code -1" to the user.
      //
      // The same race `finish` guards against applies here too: this is
      // reached after an `await`, so a cancellation may already have
      // finalized this step (e.g. `ProcessSpawner.spawn` failing while a
      // `cancel(step:)` for it is in flight). Route through the same guard
      // rather than completing unconditionally.
      guard isStillRunning(id) else {
        abandonAlreadyFinalizedStep(id)
        return
      }
      completeStep(id, outcome: .failed(StepFailure(
        kind: .launchFailed("\(error)"),
        summary: "The download tool failed to start.",
        detail: "\(error)")))
    }
  }

  private func updateProgress(_ id: StepID, _ progress: StepProgress) {
    guard let location = locate(id) else { return }
    jobs[location.job].steps[location.step].progress = progress
    publish()
  }

  private func finish(_ id: StepID, result: RunResult, context: StepContext) {
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
      return
    }
    let job = jobs[location.job]
    let step = job.steps[location.step]

    // Success is the artifact, not the exit code: the CLI's `Main` returns
    // void, so nothing sets a meaningful exit status on its own.
    let produced = FileManager.default.fileExists(atPath: context.outputFile.path)

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
    if let location = locate(id) {
      let job = jobs[location.job]
      configuration.workspace.removeStep(job: job.id, step: id)
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
    guard let location = locate(id) else { return }
    let job = jobs[location.job]

    Scheduler.complete(id, with: outcome, in: &jobs)

    configuration.workspace.removeStep(job: job.id, step: id)

    if jobs[location.job].status == .done {
      configuration.workspace.removeJob(job.id)
    } else if jobsAwaitingWorkspaceRemoval.contains(job.id) {
      removeJobWorkspaceIfSettled(job.id)
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

  /// Removes a job's workspace once nothing belonging to it is still
  /// `running`. A helper can outlive its kill signal by up to ~2s, so at the
  /// moment `cancel(job:)`'s kills return there may still be a process
  /// mid-write into this directory. If so, this defers by recording the job
  /// in `jobsAwaitingWorkspaceRemoval`; `completeStep`/`finish` call back in
  /// here the moment that last step actually clears `running`.
  private func removeJobWorkspaceIfSettled(_ id: JobID) {
    guard let job = jobs.first(where: { $0.id == id }) else { return }
    guard !job.steps.contains(where: { running[$0.id] != nil }) else {
      jobsAwaitingWorkspaceRemoval.insert(id)
      return
    }
    configuration.workspace.removeJob(id)
    jobsAwaitingWorkspaceRemoval.remove(id)
  }

  private func makeContext(job: Job, step: Step) throws -> StepContext {
    let stepDirectory = try configuration.workspace.prepareStep(job: job.id, step: step.id)
    let artifacts = try configuration.workspace.prepareArtifacts(job: job.id)

    // The CLI infers download type from the output file extension.
    let name: String = switch step.kind {
    case .downloadVideo: "video.mp4"
    case .downloadClip: "clip.mp4"
    case .downloadChat(let request): "chat.\(request.format.rawValue)"
    case .renderChat: "render.mp4"
    }

    // Guaranteed non-nil when a render runs: `Scheduler.admissible` only
    // admits a step whose `dependsOn` is `.done`, and `.done` is only
    // reachable via `.succeeded(artifact:)`. No defensive branch here — the
    // `?? ""` fallback in `ArgumentBuilder` is what covers a wiring bug, not
    // this.
    let input = step.dependsOn.flatMap { dependency in
      job.steps.first { $0.id == dependency }?.artifact
    }

    return StepContext(
      stepTempDirectory: stepDirectory,
      outputFile: artifacts.appending(path: name),
      ffmpegPath: configuration.ffmpegPath,
      inputArtifact: input)
  }

  /// Moves a finished step's output to its final destination.
  ///
  /// Distinguishes "this kind has no destination, keep it as an intermediate"
  /// from "the move itself failed" — collapsing those (e.g. via `?? file`)
  /// would report a move failure as success. `ChatRequest.destination` is the
  /// only optional one of the four; every other kind's destination is
  /// required, so `.failed` is the only way `nil` can mean anything there.
  private func move(_ file: URL, toDestinationFor kind: StepKind) -> MoveOutcome {
    let destination: URL? = switch kind {
    case .downloadVideo(let request): request.destination
    case .downloadClip(let request): request.destination
    case .downloadChat(let request): request.destination
    case .renderChat(let request): request.destination
    }
    guard let destination else { return .notApplicable }

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
