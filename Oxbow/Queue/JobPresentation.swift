import Foundation
import OxbowKit

/// `nonisolated`: the target defaults new declarations to `@MainActor`, but
/// this is a pure enum of static functions derived from other pure values,
/// with no UI dependency, and `OxbowTests` (which has no actor default of
/// its own) calls these synchronously, which requires it.
nonisolated enum JobPresentation {

  /// The step a collapsed row describes.
  ///
  /// A strict mirror of `Job.status`'s own precedence tiers, in the same
  /// order — running, then failed/blocked, then cancelled, then queued,
  /// then the last step — so a row's icon (read from `job.status`) and its
  /// progress line (derived from this function) always describe the same
  /// step and can never disagree.
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
    }
  }

  /// What a status looks like: a symbol, and the tone that says what it means.
  ///
  /// Filled circles throughout, bar the warning triangle, so the icons read as
  /// one family at 16pt — and each carries a distinct tone rather than the
  /// single shade of secondary grey they all used to share. A queue where only
  /// the failure is coloured makes every other state invisible at a glance,
  /// which is exactly the job the icon column exists to do.
  static func icon(for status: JobStatus) -> (name: String, tone: Tone) {
    switch status {
    case .queued: ("clock", .warning)
    case .running: ("arrow.down.circle.fill", .active)
    case .done: ("checkmark.circle.fill", .success)
    case .failed: ("exclamationmark.triangle.fill", .error)
    case .cancelled: ("slash.circle.fill", .neutral)
    }
  }

  /// The same family of icons for a single step.
  ///
  /// `.blocked` is the one state a job never has: a job whose step is blocked
  /// reads as `.failed`, because from outside that is what it is — something
  /// upstream broke and this will not run. A step row shows the distinction,
  /// because in the expanded view it is the difference between the step that
  /// failed and the one that merely inherited the failure.
  static func icon(for status: StepStatus) -> (name: String, tone: Tone) {
    switch status {
    case .queued: ("clock", .warning)
    case .blocked: ("minus.circle.fill", .neutral)
    case .running: ("arrow.down.circle.fill", .active)
    case .done: ("checkmark.circle.fill", .success)
    case .failed: ("exclamationmark.triangle.fill", .error)
    case .cancelled: ("slash.circle.fill", .neutral)
    }
  }

  /// What the icon conveys, said out loud.
  ///
  /// The status reaches sighted users as a colour and a shape and reaches
  /// VoiceOver as nothing at all — the image is `accessibilityHidden`, because
  /// a row that reads "checkmark circle fill, LeighXP…" is worse than one that
  /// reads "LeighXP…, finished". This is the other half of that trade.
  static func accessibilityStatus(of status: JobStatus) -> String {
    switch status {
    case .queued: "queued"
    case .running: "downloading"
    case .done: "finished"
    case .failed: "failed"
    case .cancelled: "cancelled"
    }
  }

  /// The meaning behind a status icon's colour. Named here and coloured in the
  /// view layer, so this type stays free of SwiftUI.
  enum Tone: Sendable {
    case neutral
    case active
    case success
    case warning
    case error
  }
}
