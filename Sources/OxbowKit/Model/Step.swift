import Foundation

public struct Step: Identifiable, Codable, Sendable, Equatable {
  public let id: StepID
  public let kind: StepKind
  public var status: StepStatus
  public var progress: StepProgress
  /// Artifact dependencies in consumer order; composite requires `[video, render]`. Empty means
  /// no parent. `JobTemplate` produces an acyclic graph for the scheduler's fixed-point walks.
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
  /// The completed file delivered to the user. A done step may still be an intermediate, so
  /// `artifact` alone is insufficient; require a delivery destination.
  public var deliveredArtifact: URL? {
    kind.deliveryDestination != nil ? artifact : nil
  }
}

extension Step {
  private enum CodingKeys: String, CodingKey {
    case id, kind, status, progress, dependsOn, artifact
  }

  /// Accept legacy queues where `dependsOn` was one optional `StepID`.
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
