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

  static func job(_ n: Int, createdAt seconds: TimeInterval = 0, _ steps: Step...) -> Job {
    Job(
      id: jobID(n),
      created: Date(timeIntervalSince1970: seconds),
      title: "job \(n)",
      steps: steps)
  }
}
