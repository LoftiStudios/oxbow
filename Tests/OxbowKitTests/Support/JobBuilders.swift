import Foundation
@testable import OxbowKit

/// Terse, deterministic job construction for scheduler tests.
enum Build {
  static func stepID(_ n: Int) -> StepID {
    StepID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!)
  }

  static func jobID(_ n: Int) -> JobID {
    JobID(rawValue: UUID(uuidString: "00000000-0000-0000-0001-\(String(format: "%012d", n))")!)
  }

  /// A deterministic `nextStepID` closure for tests that don't need to name
  /// individual steps up front — just that they come out distinct and stable.
  static func sequentialStepIDs() -> () -> StepID {
    var n = 0
    return {
      n += 1
      return stepID(n)
    }
  }

  /// A `.network` step — any of the download verbs contends the same way.
  static func network(_ n: Int, _ status: StepStatus = .queued, dependsOn: [StepID] = []) -> Step {
    Step(
      id: stepID(n),
      kind: .downloadChat(ChatRequest(videoID: "v", format: .json)),
      status: status,
      dependsOn: dependsOn)
  }

  /// A `.compute` step.
  static func compute(_ n: Int, _ status: StepStatus = .queued, dependsOn: [StepID] = []) -> Step {
    Step(
      id: stepID(n),
      kind: .renderChat(RenderRequest(destination: URL(filePath: "/tmp/o.mp4"))),
      status: status,
      dependsOn: dependsOn)
  }

  /// A `.compute` step that consumes two artifacts.
  static func composite(
    _ n: Int,
    _ status: StepStatus = .queued,
    dependsOn: [StepID] = []) -> Step
  {
    Step(
      id: stepID(n),
      kind: .composite(CompositeRequest(
        framerate: 60,
        duration: .seconds(60),
        destination: URL(filePath: "/tmp/c.mp4"))),
      status: status,
      dependsOn: dependsOn)
  }

  static func job(_ n: Int, createdAt seconds: TimeInterval = 0, _ steps: Step...) -> Job {
    Job(
      id: jobID(n),
      created: Date(timeIntervalSince1970: seconds),
      title: "job \(n)",
      steps: steps)
  }
}
