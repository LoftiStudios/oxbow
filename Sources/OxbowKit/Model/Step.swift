import Foundation

public struct Step: Identifiable, Codable, Sendable, Equatable {
  public let id: StepID
  public let kind: StepKind
  public var status: StepStatus
  public var progress: StepProgress
  /// The steps whose artifacts this one consumes, in the order the consuming
  /// step expects them. **Order is the contract**: a composite's parents are
  /// `[video, render]`, and `StepContext.inputArtifacts` preserves that order.
  ///
  /// Empty means no parent. Steps form a DAG rather than a forest — a
  /// composite has two parents — but `JobTemplate` never builds a cycle, so
  /// `Scheduler`'s fixed-point walks still terminate.
  public let dependsOn: [StepID]
  public var artifact: URL?

  public init(
    id: StepID,
    kind: StepKind,
    status: StepStatus = .queued,
    progress: StepProgress = StepProgress(),
    dependsOn: [StepID] = [],
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

extension Step {
  private enum CodingKeys: String, CodingKey {
    case id, kind, status, progress, dependsOn, artifact
  }

  /// `dependsOn` was a single optional `StepID` until 2026-08-25. A queue
  /// persisted before then decodes here rather than failing and stranding the
  /// user's in-flight jobs, so no migration step is needed.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(StepID.self, forKey: .id)
    self.kind = try container.decode(StepKind.self, forKey: .kind)
    self.status = try container.decode(StepStatus.self, forKey: .status)
    self.progress = try container.decode(StepProgress.self, forKey: .progress)
    self.artifact = try container.decodeIfPresent(URL.self, forKey: .artifact)

    if let many = try? container.decode([StepID].self, forKey: .dependsOn) {
      self.dependsOn = many
    } else if let one = try container.decodeIfPresent(StepID.self, forKey: .dependsOn) {
      self.dependsOn = [one]
    } else {
      self.dependsOn = []
    }
  }
}
