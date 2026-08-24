import Foundation
import OxbowKit

/// `nonisolated`: the target defaults new declarations to `@MainActor`, but
/// this is a pure enum of static functions derived from other pure values,
/// with no UI dependency, and `OxbowTests` (which has no actor default of
/// its own) calls these synchronously, which requires it.
nonisolated enum JobPresentation {

  /// The step a collapsed row describes.
  ///
  /// Precedence mirrors `Job.status` so a row's icon and its progress line
  /// can never describe different steps.
  static func representativeStep(of job: Job) -> Step? {
    if let running = job.steps.first(where: { $0.status == .running }) { return running }
    if let failed = job.steps.first(where: {
      if case .failed = $0.status { return true }
      return $0.status == .blocked
    }) { return failed }
    if let pending = job.steps.first(where: { $0.status == .queued }) { return pending }
    return job.steps.last
  }

  static func label(for kind: StepKind) -> String {
    switch kind {
    case .downloadVideo: "Download video"
    case .downloadClip: "Download clip"
    case .downloadChat: "Download chat"
    case .renderChat: "Render chat"
    }
  }

  static func icon(for status: JobStatus) -> (name: String, isError: Bool) {
    switch status {
    case .queued: ("clock", false)
    case .running: ("arrow.down.circle", false)
    case .done: ("checkmark.circle.fill", false)
    case .failed: ("exclamationmark.triangle.fill", true)
    case .cancelled: ("slash.circle", false)
    }
  }
}
