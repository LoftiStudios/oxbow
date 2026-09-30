import Foundation

/// One crash, as MetricKit describes it on the launch after it happened.
///
/// Decoded from `MXCrashDiagnostic.jsonRepresentation()` rather than from the
/// MetricKit objects themselves: they have no public initialisers, so JSON is
/// the only form a test can construct, and the app hands it over unchanged.
/// See docs/design/crash-reports.md.
public struct CrashReport: Equatable, Sendable {

  public struct Frame: Equatable, Sendable {
    public let binaryName: String
    public let binaryUUID: String
    /// Offset from the start of the binary's text segment. For Oxbow's own
    /// frames this is what the release's dSYM turns back into a function.
    public let offset: Int
  }

  public let appVersion: String
  public let appBuild: String
  public let osVersion: String
  public let deviceType: String?
  public let exceptionType: Int?
  public let signal: Int?
  public let terminationReason: String?
  /// An Objective-C exception's message, when the crash was one.
  public let exceptionMessage: String?
  /// The crashed thread, innermost frame first.
  public let frames: [Frame]

  /// Nil when the data is not a crash diagnostic MetricKit would produce.
  public init?(json: Data) {
    guard let raw = try? JSONDecoder().decode(RawDiagnostic.self, from: json) else { return nil }
    let meta = raw.diagnosticMetaData
    appVersion = meta.appVersion ?? "unknown"
    appBuild = meta.appBuildVersion ?? "unknown"
    osVersion = meta.osVersion ?? "unknown"
    deviceType = meta.deviceType
    exceptionType = meta.exceptionType
    signal = meta.signal
    terminationReason = meta.terminationReason
    exceptionMessage = meta.exceptionReason?.composedMessage

    // A crash has one stack per thread, each a single chain through
    // `subFrames`. The crashed thread is the attributed one; if MetricKit ever
    // omits the flag, the first thread is the likeliest culprit.
    let stacks = raw.callStackTree.callStacks
    let crashed = stacks.first { $0.threadAttributed == true } ?? stacks.first
    var frames: [Frame] = []
    var next = crashed?.callStackRootFrames.first
    while let frame = next {
      frames.append(Frame(
        binaryName: frame.binaryName ?? "???",
        binaryUUID: frame.binaryUUID ?? "",
        offset: frame.offsetIntoBinaryTextSegment ?? 0))
      next = frame.subFrames?.first
    }
    self.frames = frames
  }

  /// "EXC_BAD_ACCESS (SIGSEGV)", or as much of it as the diagnostic carries.
  public var summary: String {
    let exception = exceptionType.map { Self.exceptionNames[$0] ?? "exception \($0)" }
    let signal = signal.map { Self.signalNames[$0] ?? "signal \($0)" }
    switch (exception, signal) {
    case let (exception?, signal?): return "\(exception) (\(signal))"
    case let (exception?, nil): return exception
    case let (nil, signal?): return signal
    case (nil, nil): return "Crash"
    }
  }

  // <mach/exception_types.h> and <sys/signal.h>: only the ones a crash reports.
  private static let exceptionNames = [
    1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC",
    5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 10: "EXC_CRASH",
    11: "EXC_RESOURCE", 12: "EXC_GUARD",
  ]
  private static let signalNames = [
    4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 9: "SIGKILL",
    10: "SIGBUS", 11: "SIGSEGV",
  ]

  // MARK: - MetricKit's JSON

  private struct RawDiagnostic: Decodable {
    let callStackTree: CallStackTree
    let diagnosticMetaData: MetaData
  }

  private struct CallStackTree: Decodable {
    let callStacks: [CallStack]
  }

  private struct CallStack: Decodable {
    let threadAttributed: Bool?
    let callStackRootFrames: [RawFrame]
  }

  private struct RawFrame: Decodable {
    let binaryName: String?
    let binaryUUID: String?
    let offsetIntoBinaryTextSegment: Int?
    let subFrames: [RawFrame]?
  }

  private struct MetaData: Decodable {
    let appVersion: String?
    let appBuildVersion: String?
    let osVersion: String?
    let deviceType: String?
    let exceptionType: Int?
    let signal: Int?
    let terminationReason: String?
    let exceptionReason: ExceptionReason?
  }

  private struct ExceptionReason: Decodable {
    let composedMessage: String?
  }
}
