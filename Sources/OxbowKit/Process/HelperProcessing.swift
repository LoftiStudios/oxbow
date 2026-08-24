import Foundation

/// What the engine needs from a running helper.
///
/// A protocol solely so tests can substitute a fake and exercise the engine's
/// logic without spawning processes. `HelperProcess` is the only real
/// implementation.
public protocol HelperProcessing: Sendable {
  func run(
    _ launch: Launch,
    onOutput: @escaping @Sendable (ParsedLine) async -> Void)
    async throws -> RunResult

  func cancel() async
}

extension HelperProcess: HelperProcessing {}
