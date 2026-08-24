import Foundation

public struct Step: Identifiable, Codable, Sendable, Equatable {
  public let id: StepID
  public let kind: StepKind
  public var status: StepStatus
  public var progress: StepProgress
  /// The step whose artifact this one consumes.
  ///
  /// Always earlier in `Job.steps`, but named explicitly rather than assumed to
  /// be the immediate predecessor: in video+chat+render the render depends on
  /// step 2, not step 1. At most one parent, so this is a forest and never
  /// needs a topological sort.
  public let dependsOn: StepID?
  public var artifact: URL?

  public init(
    id: StepID,
    kind: StepKind,
    status: StepStatus = .queued,
    progress: StepProgress = StepProgress(),
    dependsOn: StepID? = nil,
    artifact: URL? = nil)
  {
    self.id = id
    self.kind = kind
    self.status = status
    self.progress = progress
    self.dependsOn = dependsOn
    self.artifact = artifact
  }
}
