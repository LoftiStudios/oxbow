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

  private let configuration: Configuration
  private var jobs: [Job] = []
  private var running: [StepID: RunningStep] = [:]
  private var observers: [UUID: AsyncStream<[Job]>.Continuation] = [:]
  private var saveTask: Task<Void, Never>?

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
    await running[id]?.process.cancel()
    Scheduler.cancel(id, in: &jobs)
    tick()
  }

  public func cancel(job id: JobID) async {
    guard let job = jobs.first(where: { $0.id == id }) else { return }
    for step in job.steps {
      await running[step.id]?.process.cancel()
    }
    Scheduler.cancel(job: id, in: &jobs)
    configuration.workspace.removeJob(id)
    tick()
  }

  /// Writes any pending state immediately. Call on app termination.
  public func flush() async {
    saveTask?.cancel()
    saveTask = nil
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

    let context: StepContext
    do {
      context = try makeContext(job: job, step: step)
    } catch {
      Scheduler.complete(id, with: .failed(StepFailure(
        kind: .launchFailed("\(error)"),
        summary: "Could not create a working directory.")), in: &jobs)
      tick()
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
    var result: RunResult
    do {
      result = try await process.run(launch) { [weak self] line in
        guard case .status(let progress) = line else { return }
        await self?.updateProgress(id, progress)
      }
    } catch {
      result = RunResult(status: .exited(-1), standardError: "\(error)")
    }

    finish(id, result: result, context: context)
  }

  private func updateProgress(_ id: StepID, _ progress: StepProgress) {
    guard let location = locate(id) else { return }
    jobs[location.job].steps[location.step].progress = progress
    publish()
  }

  private func finish(_ id: StepID, result: RunResult, context: StepContext) {
    running[id] = nil

    guard let location = locate(id) else { return }
    let job = jobs[location.job]
    let step = job.steps[location.step]

    // Success is the artifact, not the exit code: the CLI's `Main` returns
    // void, so nothing sets a meaningful exit status on its own.
    let produced = FileManager.default.fileExists(atPath: context.outputFile.path)

    if let failure = FailureInterpreter.interpret(
      exitStatus: result.status,
      standardError: result.standardError,
      artifactExists: produced)
    {
      Scheduler.complete(id, with: .failed(failure), in: &jobs)
    } else {
      // The Swift parent moves the finished file out; the helper only ever
      // writes inside our workspace.
      let final = move(context.outputFile, toDestinationFor: step.kind) ?? context.outputFile
      Scheduler.complete(id, with: .succeeded(artifact: final), in: &jobs)
    }

    configuration.workspace.removeStep(job: job.id, step: id)

    if jobs[location.job].status == .done {
      configuration.workspace.removeJob(job.id)
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

  /// Returns the final location, or nil when the step has no destination and
  /// its output stays in the workspace as an intermediate.
  private func move(_ file: URL, toDestinationFor kind: StepKind) -> URL? {
    let destination: URL? = switch kind {
    case .downloadVideo(let request): request.destination
    case .downloadClip(let request): request.destination
    case .downloadChat(let request): request.destination
    case .renderChat(let request): request.destination
    }
    guard let destination else { return nil }

    do {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
      } else {
        try FileManager.default.moveItem(at: file, to: destination)
      }
      return destination
    } catch {
      return nil
    }
  }
}
