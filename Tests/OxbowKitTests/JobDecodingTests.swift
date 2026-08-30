import Foundation
import Testing
@testable import OxbowKit

@Suite("Job decoding")
struct JobDecodingTests {

  /// Mirrors `Job`'s shape before `replacesExistingFile` existed, so the
  /// fixture is generated rather than hand-written — hand-writing it means
  /// hand-writing `Step`'s and `StepKind`'s synthesised encodings, which is
  /// exactly the thing that would drift.
  private struct LegacyJob: Encodable {
    let id: JobID
    let created: Date
    let title: String
    let steps: [Step]
  }

  private func legacy() throws -> Data {
    try JSONEncoder().encode(LegacyJob(
      id: JobID(rawValue: UUID()),
      created: Date(timeIntervalSince1970: 1_787_081_691),
      title: "t",
      steps: [Step(
        id: Build.stepID(1),
        kind: .renderChat(RenderRequest(destination: URL(filePath: "/tmp/o.mp4"))))]))
  }

  /// A queue persisted before the flag existed must still load — failing
  /// here would strand every in-flight job the user had.
  @Test func decodesAJobPersistedBeforeTheFlagExisted() throws {
    let job = try JSONDecoder().decode(Job.self, from: legacy())
    #expect(job.title == "t")
  }

  /// Absent must read as `false`, not as permission. An old job resumes
  /// having authorized nothing, so delivery has to step around whatever it
  /// finds rather than assume a warning was shown and accepted.
  @Test func aJobPersistedBeforeTheFlagAuthorizesNoReplacement() throws {
    let job = try JSONDecoder().decode(Job.self, from: legacy())
    #expect(!job.replacesExistingFile)
  }

  @Test func roundTripsTheFlag() throws {
    let original = Job(
      id: JobID(rawValue: UUID()), created: Date(timeIntervalSince1970: 0), title: "t", steps: [],
      replacesExistingFile: true)
    let decoded = try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(original))
    #expect(decoded.replacesExistingFile)
  }
}
