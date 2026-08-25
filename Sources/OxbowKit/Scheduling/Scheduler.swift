import Foundation

/// The queue's rules, as pure functions.
///
/// Nothing here performs I/O, reads a clock, or touches a process. That is
/// deliberate: it makes every scheduling rule a table-driven unit test rather
/// than something you can only observe by running real downloads.
public enum Scheduler {

  /// Which queued steps may start, given what is already running.
  ///
  /// Three rules, applied in order:
  ///   1. Eligible — status is `.queued` and any dependency is `.done`.
  ///   2. Capacity — at most one running step per resource class. This cap is
  ///      load-bearing outside the scheduler: it is what bounds concurrent
  ///      `HelperProcess.run` calls, each of which pins three *blocking*
  ///      syscalls on the cooperative thread pool. Read `HelperProcess`'s note
  ///      on thread pinning before relaxing it.
  ///   3. Order — oldest job first, then step order within the job.
  public static func admissible(jobs: [Job], running: Set<StepID>) -> [StepID] {
    var statusByID: [StepID: StepStatus] = [:]
    for job in jobs {
      for step in job.steps { statusByID[step.id] = step.status }
    }

    var occupied: Set<ResourceClass> = []
    for job in jobs {
      for step in job.steps where running.contains(step.id) {
        occupied.insert(step.kind.resource)
      }
    }

    var admitted: [StepID] = []
    for job in jobs.sorted(by: isOlder) {
      for step in job.steps {
        guard step.status == .queued else { continue }

        if let dependency = step.dependsOn {
          guard statusByID[dependency] == .done else { continue }
        }

        let resource = step.kind.resource
        guard !occupied.contains(resource) else { continue }

        occupied.insert(resource)
        admitted.append(step.id)
      }
    }
    return admitted
  }

  /// Folds a finished step's outcome back in.
  ///
  /// Anything other than success blocks the step's dependents, transitively.
  public static func complete(_ id: StepID, with outcome: StepOutcome, in jobs: inout [Job]) {
    guard let location = locate(id, in: jobs) else { return }

    switch outcome {
    case .succeeded(let artifact):
      jobs[location.job].steps[location.step].status = .done
      jobs[location.job].steps[location.step].artifact = artifact
      return

    case .failed(let failure):
      jobs[location.job].steps[location.step].status = .failed(failure)

    case .cancelled:
      jobs[location.job].steps[location.step].status = .cancelled
    }

    blockDependents(of: id, inJobAt: location.job, in: &jobs)
  }

  /// Requeues a failed or cancelled step and releases whatever it was blocking.
  /// Successful siblings are untouched — that is the point of retry in place.
  /// Only acts on `.failed` or `.cancelled` steps; other statuses are no-ops.
  public static func retry(_ id: StepID, in jobs: inout [Job]) {
    guard let location = locate(id, in: jobs) else { return }
    switch jobs[location.job].steps[location.step].status {
    case .failed, .cancelled:
      jobs[location.job].steps[location.step].status = .queued
      jobs[location.job].steps[location.step].artifact = nil
      unblockDependents(of: id, inJobAt: location.job, in: &jobs)
    case .queued, .blocked, .running, .done:
      return
    }
  }

  /// Retries every unfinished step of a job — the counterpart to
  /// `cancel(job:)`, and the only correct shape for retry at the job level.
  ///
  /// **Why not just retry the representative step.** `cancel(job:)` settles
  /// *every* unfinished step as `.cancelled`, so retrying one of them would
  /// requeue that step and leave its siblings cancelled: the job would run its
  /// first step, then sit there reading as cancelled with nothing left able to
  /// move it. A failed job is different — its dependents are `.blocked`, and
  /// retrying the failure unblocks them — but one call has to be right for
  /// both, so it retries them all.
  ///
  /// Nothing here re-runs a step that succeeded. There is no resume anywhere
  /// in this stack, so a retried step starts from scratch; re-downloading a
  /// finished 3GB VOD because the chat render after it failed would be a very
  /// expensive way to express that.
  public static func retry(job id: JobID, in jobs: inout [Job]) {
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }

    // Collected first, then retried: `retry(_:in:)` unblocks dependents as it
    // goes, so the statuses this reads would otherwise change underneath it.
    let retryable = jobs[index].steps.compactMap { step -> StepID? in
      switch step.status {
      case .failed, .cancelled: step.id
      case .queued, .blocked, .running, .done: nil
      }
    }
    for step in retryable { retry(step, in: &jobs) }
  }

  /// Cancels a single step. Only acts on `.queued`, `.blocked`, or `.running` steps;
  /// finished steps (`.done`, `.failed`, `.cancelled`) are no-ops.
  public static func cancel(_ id: StepID, in jobs: inout [Job]) {
    guard let location = locate(id, in: jobs) else { return }
    switch jobs[location.job].steps[location.step].status {
    case .queued, .blocked, .running:
      complete(id, with: .cancelled, in: &jobs)
    case .done, .failed, .cancelled:
      return
    }
  }

  /// Cancels every unfinished step. Finished steps keep their artifacts.
  public static func cancel(job id: JobID, in jobs: inout [Job]) {
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    for stepIndex in jobs[index].steps.indices {
      switch jobs[index].steps[stepIndex].status {
      case .queued, .blocked, .running:
        jobs[index].steps[stepIndex].status = .cancelled
      case .done, .failed, .cancelled:
        continue
      }
    }
  }

  // MARK: - Private

  private static func locate(_ id: StepID, in jobs: [Job]) -> (job: Int, step: Int)? {
    for (jobIndex, job) in jobs.enumerated() {
      if let stepIndex = job.steps.firstIndex(where: { $0.id == id }) {
        return (jobIndex, stepIndex)
      }
    }
    return nil
  }

  /// Walks forward to a fixed point. Steps have at most one parent, so a single
  /// pass per newly-blocked step terminates.
  private static func blockDependents(of id: StepID, inJobAt jobIndex: Int, in jobs: inout [Job]) {
    var frontier: Set<StepID> = [id]

    while !frontier.isEmpty {
      var next: Set<StepID> = []
      for stepIndex in jobs[jobIndex].steps.indices {
        let step = jobs[jobIndex].steps[stepIndex]
        guard let parent = step.dependsOn, frontier.contains(parent) else { continue }
        guard step.status == .queued || step.status == .running else { continue }
        jobs[jobIndex].steps[stepIndex].status = .blocked
        next.insert(step.id)
      }
      frontier = next
    }
  }

  private static func unblockDependents(of id: StepID, inJobAt jobIndex: Int, in jobs: inout [Job]) {
    var frontier: Set<StepID> = [id]

    while !frontier.isEmpty {
      var next: Set<StepID> = []
      for stepIndex in jobs[jobIndex].steps.indices {
        let step = jobs[jobIndex].steps[stepIndex]
        guard let parent = step.dependsOn, frontier.contains(parent) else { continue }
        guard step.status == .blocked else { continue }
        jobs[jobIndex].steps[stepIndex].status = .queued
        next.insert(step.id)
      }
      frontier = next
    }
  }

  /// Deterministic ordering. Falling back to the id keeps the result stable
  /// when two jobs share a creation timestamp.
  private static func isOlder(_ a: Job, _ b: Job) -> Bool {
    if a.created != b.created { return a.created < b.created }
    return a.id.rawValue.uuidString < b.id.rawValue.uuidString
  }
}
