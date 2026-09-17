import Foundation
import OxbowKit

/// Pure presentation helpers opt out of the app's default main-actor isolation.
nonisolated enum JobPresentation {

  /// Match Job.status precedence so the collapsed row's icon and details describe the same
  /// state.
  static func representativeStep(of job: Job) -> Step? {
    if let running = job.steps.first(where: { $0.status == .running }) { return running }
    if let failed = job.steps.first(where: {
      if case .failed = $0.status { return true }
      return $0.status == .blocked
    }) { return failed }
    if let cancelled = job.steps.first(where: { $0.status == .cancelled }) { return cancelled }
    if let pending = job.steps.first(where: { $0.status == .queued }) { return pending }
    return job.steps.last
  }

  static func label(for kind: StepKind) -> String {
    switch kind {
    case .downloadVideo: "Download video"
    case .downloadClip: "Download clip"
    case .downloadChat: "Download chat"
    case .renderChat: "Render chat"
    case .composite: "Combine video and chat"
    case .assemble: "Assemble"
    }
  }

  /// Shared status symbol and semantic tone.
  static func icon(for status: JobStatus) -> (name: String, tone: Tone) {
    switch status {
    case .queued: ("clock", .pending)
    case .running: ("arrow.down.circle.fill", .active)
    case .done: ("checkmark.circle.fill", .success)
    case .failed: ("exclamationmark.triangle.fill", .error)
    case .cancelled: ("slash.circle.fill", .neutral)
    }
  }

  /// Step rows distinguish blocked dependencies from failures; the containing job reports
  /// failed for either.
  static func icon(for status: StepStatus) -> (name: String, tone: Tone) {
    switch status {
    case .queued: ("clock", .pending)
    case .blocked: ("minus.circle.fill", .neutral)
    case .running: ("arrow.down.circle.fill", .active)
    case .done: ("checkmark.circle.fill", .success)
    case .failed: ("exclamationmark.triangle.fill", .error)
    case .cancelled: ("slash.circle.fill", .neutral)
    }
  }

  /// Text equivalent of the hidden status icon for VoiceOver.
  static func accessibilityStatus(of status: JobStatus) -> String {
    switch status {
    case .queued: "queued"
    case .running: "downloading"
    case .done: "finished"
    case .failed: "failed"
    case .cancelled: "cancelled"
    }
  }

  /// View-independent status tones. Pending means still waiting; neutral covers cancelled or
  /// blocked work. Neither requires a warning colour.
  enum Tone: Sendable, Equatable {
    case neutral
    case pending
    case active
    case success
    case error
  }
}
