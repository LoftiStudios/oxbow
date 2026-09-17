import Foundation

public struct Job: Identifiable, Codable, Sendable, Equatable {
  public let id: JobID
  public let created: Date
  public var title: String
  /// Ordered. Index order is execution order.
  public var steps: [Step]
  /// Explicit replacement permission captured at intake; see
  /// `JobTemplate.replacesExistingFile`.
  public let replacesExistingFile: Bool

  public init(
    id: JobID,
    created: Date,
    title: String,
    steps: [Step],
    replacesExistingFile: Bool = false)
  {
    self.id = id
    self.created = created
    self.title = title
    self.steps = steps
    self.replacesExistingFile = replacesExistingFile
  }

  /// Derived status with running > failed > cancelled precedence; active work must not appear
  /// finished.
  public var status: JobStatus {
    if steps.contains(where: { $0.status == .running }) { return .running }
    if steps.contains(where: {
      if case .failed = $0.status { return true }
      return $0.status == .blocked
    }) { return .failed }
    if steps.contains(where: { $0.status == .cancelled }) { return .cancelled }
    if steps.allSatisfy({ $0.status == .done }) { return .done }
    return .queued
  }

  /// Delivered artifacts from successful destination-bearing steps, in step order. Shared by
  /// Get Info and Finder actions; excludes workspace intermediates.
  public var deliveredFiles: [URL] {
    steps.compactMap(\.deliveredArtifact)
  }

  /// Derive media identity from the video/clip step only, not chat request fields.
  public var mediaIdentifier: String? {
    for step in steps {
      switch step.kind {
      case .downloadVideo(let request): return request.videoID
      case .downloadClip(let request): return request.clipSlug
      case .downloadChat, .renderChat, .composite, .assemble: continue
      }
    }
    return nil
  }
}

extension Job {
  private enum CodingKeys: String, CodingKey {
    case id, created, title, steps, replacesExistingFile
  }

  /// Older queues default replacesExistingFile to false, preserving existing destination files
  /// without a migration.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(JobID.self, forKey: .id),
      created: try container.decode(Date.self, forKey: .created),
      title: try container.decode(String.self, forKey: .title),
      steps: try container.decode([Step].self, forKey: .steps),
      replacesExistingFile:
        try container.decodeIfPresent(Bool.self, forKey: .replacesExistingFile) ?? false)
  }
}
