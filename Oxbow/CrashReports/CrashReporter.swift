import Foundation
import MetricKit
import Observation
import OxbowKit

/// The last crash MetricKit reported, held until the user reports or dismisses
/// it. In memory only: MetricKit delivers a crash once, on the next launch,
/// and a report nobody acts on by the time they quit again is let go.
@MainActor
@Observable
final class CrashReportModel {
  static let shared = CrashReportModel()

  private(set) var pending: CrashReport?

  func receive(_ reports: [CrashReport]) {
    if let latest = reports.last { pending = latest }
  }

  func dismiss() {
    pending = nil
  }
}

/// Subscribes to MetricKit and forwards crash diagnostics to the model.
///
/// **Nonisolated, deliberately.** The target defaults to the main actor, and
/// MetricKit calls `didReceive` on a background queue; an isolated subscriber
/// fails Swift's executor check there and traps — on the launch after a crash,
/// so it crashes again, and every launch after that. The fixture in
/// `Tests/OxbowKitTests/Fixtures/metrickit-crash.json` is that crash.
nonisolated final class CrashReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
  /// MetricKit does not document whether it retains subscribers.
  static let shared = CrashReporter()

  func start() {
    MXMetricManager.shared.add(self)
  }

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    let reports = payloads
      .flatMap { $0.crashDiagnostics ?? [] }
      .compactMap { CrashReport(json: $0.jsonRepresentation()) }
    guard !reports.isEmpty else { return }
    Task { @MainActor in CrashReportModel.shared.receive(reports) }
  }
}
