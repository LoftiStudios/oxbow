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
  ///   2. Capacity — at most one running step per resource class.
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

  /// Deterministic ordering. Falling back to the id keeps the result stable
  /// when two jobs share a creation timestamp.
  private static func isOlder(_ a: Job, _ b: Job) -> Bool {
    if a.created != b.created { return a.created < b.created }
    return a.id.rawValue.uuidString < b.id.rawValue.uuidString
  }
}
