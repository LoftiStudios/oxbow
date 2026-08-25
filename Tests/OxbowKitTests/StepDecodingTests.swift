import Foundation
import Testing
@testable import OxbowKit

@Suite("Step decoding")
struct StepDecodingTests {

  /// Mirrors `Step`'s pre-array shape so the fixture is generated rather than
  /// hand-written — hand-writing it means hand-writing StepKind's synthesised
  /// encoding, which is exactly the thing that would drift.
  private struct LegacyStep: Encodable {
    let id: StepID
    let kind: StepKind
    let status: StepStatus
    let progress: StepProgress
    let dependsOn: StepID?
    let artifact: URL?
  }

  private func legacy(dependsOn: StepID?) throws -> Data {
    try JSONEncoder().encode(LegacyStep(
      id: Build.stepID(2),
      kind: .renderChat(RenderRequest(destination: URL(filePath: "/tmp/o.mp4"))),
      status: .queued,
      progress: StepProgress(),
      dependsOn: dependsOn,
      artifact: nil))
  }

  @Test func decodesALegacyScalarDependencyAsASingleElementArray() throws {
    let step = try JSONDecoder().decode(Step.self, from: legacy(dependsOn: Build.stepID(1)))
    #expect(step.dependsOn == [Build.stepID(1)])
  }

  @Test func decodesALegacyNullDependencyAsEmpty() throws {
    let step = try JSONDecoder().decode(Step.self, from: legacy(dependsOn: nil))
    #expect(step.dependsOn.isEmpty)
  }

  @Test func roundTripsTheArrayForm() throws {
    let original = Step(
      id: Build.stepID(3),
      kind: .renderChat(RenderRequest(destination: URL(filePath: "/tmp/o.mp4"))),
      dependsOn: [Build.stepID(1), Build.stepID(2)])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(Step.self, from: data)
    #expect(decoded.dependsOn == [Build.stepID(1), Build.stepID(2)])
  }
}
