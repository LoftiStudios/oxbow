import Foundation

/// Pure scheduling rules, independent of I/O, clocks, and processes.
public enum Scheduler {

  /// Admit queued steps with every dependency done, at most one per resource class, oldest job
  /// then step order. This also bounds helper concurrency; each invocation uses three dedicated
  /// blocking threads.
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

        // admissible(): every parent must be finished, not just one.
        guard step.dependsOn.allSatisfy({ statusByID[$0] == .done }) else { continue }

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

  /// Retries failed/cancelled steps and releases blocked dependents. Preserves successful
  /// siblings; other statuses are no-ops.
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

  /// Retries all failed/cancelled steps while preserving successful ones. Retrying only a
  /// representative step would leave the other independently cancelled siblings unable to run.
  public static func retry(job id: JobID, in jobs: inout [Job]) {
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }

    // Collect IDs before retry mutates dependent statuses.
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

  /// Walks forward to a fixed point. `JobTemplate` never builds a cycle, so
  /// even with a composite's two parents this still terminates.
  private static func blockDependents(of id: StepID, inJobAt jobIndex: Int, in jobs: inout [Job]) {
    var frontier: Set<StepID> = [id]

    while !frontier.isEmpty {
      var next: Set<StepID> = []
      for stepIndex in jobs[jobIndex].steps.indices {
        let step = jobs[jobIndex].steps[stepIndex]
        // blockDependents(): any parent entering the frontier blocks the child.
        guard step.dependsOn.contains(where: { frontier.contains($0) }) else { continue }
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
        // Unblock only when no parent still needs its own retry. Queued/running parents are
        // allowed here; `admissible` still requires all parents done before launch.
        guard step.dependsOn.contains(where: { frontier.contains($0) }) else { continue }
        guard step.status == .blocked else { continue }
        guard step.dependsOn.allSatisfy({ id in
          switch jobs[jobIndex].steps.first(where: { $0.id == id })?.status {
          case .failed, .cancelled, .blocked: false
          case .queued, .running, .done, nil: true
          }
        }) else { continue }
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
