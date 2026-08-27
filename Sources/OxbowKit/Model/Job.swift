import Foundation

public struct Job: Identifiable, Codable, Sendable, Equatable {
  public let id: JobID
  public let created: Date
  public var title: String
  /// Ordered. Index order is execution order.
  public var steps: [Step]

  public init(id: JobID, created: Date, title: String, steps: [Step]) {
    self.id = id
    self.created = created
    self.title = title
    self.steps = steps
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
}
