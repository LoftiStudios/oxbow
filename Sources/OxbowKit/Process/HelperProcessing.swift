import Foundation

/// Helper interface injected into the engine for process-free tests.
public protocol HelperProcessing: Sendable {
  func run(
    _ launch: Launch,
    onOutput: @escaping @Sendable (ParsedLine) async -> Void)
    async throws -> RunResult

  func cancel() async
}

extension HelperProcess: HelperProcessing {}
