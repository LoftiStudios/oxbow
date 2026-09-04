import Foundation

public struct Job: Identifiable, Codable, Sendable, Equatable {
  public let id: JobID
  public let created: Date
  public var title: String
  /// Ordered. Index order is execution order.
  public var steps: [Step]
  /// Whether the user was told a file already sat at this job's destination
  /// and chose to replace it. See `JobTemplate.replacesExistingFile` for why
  /// the decision is carried rather than re-derived, and `QueueEngine.move`
  /// for what each value does at delivery.
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

  /// Derived, never stored. A stored summary can drift from the steps it
  /// summarises, and drift is what makes a queue feel haunted.
  ///
  /// Precedence is deliberate: running beats failed beats cancelled, so a job
  /// still doing work never reads as finished.
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

  /// The files this job actually delivered — one entry per step whose kind
  /// carries a real destination and that has succeeded, in step order.
  ///
  /// The single definition both the app layer's "what does Show in Finder
  /// reveal" and "what did Get Info list as delivered" answer from, so the
  /// two can never compute it two different ways. See
  /// `Step.deliveredArtifact` for what excludes a job workspace intermediate
  /// even once its step is `.done`.
  public var deliveredFiles: [URL] {
    steps.compactMap(\.deliveredArtifact)
  }

  /// Which video or clip this job is for, or nil if it downloads no media.
  ///
  /// **Only the media step answers.** A `.video` job seeds its
  /// `ChatRequest.videoID` with the same id (see `JobTemplate.renderInput`),
  /// so reading whichever step happens to carry a `videoID` would look
  /// correct on a VOD and be wrong everywhere else: a clip job's chat step
  /// carries the *slug* in that field, and a chatless job's carries `""`.
  ///
  /// Derived rather than stored, for the reason `status` is: a stored copy
  /// can drift from the steps it summarises.
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

  /// `replacesExistingFile` did not exist until 2026-08-30. A queue persisted
  /// before then decodes here rather than failing and stranding the user's
  /// in-flight jobs, so no migration step is needed.
  ///
  /// Absent reads as `false`, which is the safe direction: an old job resumes
  /// having authorized nothing, so delivery steps around whatever it finds
  /// rather than assuming permission nobody gave.
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
