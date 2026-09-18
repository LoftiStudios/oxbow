import Foundation

/// Pure per-sweep automatic-download policy. Callers supply destination-volume capacity,
/// destination reachability, and the current reserve. Accept a downloadable prefix whose
/// estimated peak leaves that reserve; demotions are recomputed next sweep rather than
/// persisted.
public enum AutoDownloadPolicy {

  /// Distinguish automatic-off from submit([]), which means enabled but no work to submit.
  public enum Decision: Equatable, Sendable {
    case submit([ChannelArchive])
    case demoted(Reason)
    case notAutomatic
  }

  /// Why a watch's automatic downloading was demoted to notify-only this
  /// sweep. Each case carries what a person needs to be told, not just that
  /// something went wrong.
  public enum Reason: Equatable, Sendable {
    /// needed is the next archive's cost, distinct from the standing free-space reserve.
    case belowFloor(needed: Int64, available: Int64, floor: Int64)
    case destinationUnreachable(String)

    /// Credential-restricted archives cannot be fetched by Oxbow's anonymous downloader.
    case contentRestricted

    /// The sentence a finding or a settings row shows for this reason.
    public var sentence: String {
      switch self {
      case .belowFloor(let needed, let available, let floor):
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let neededText = formatter.string(fromByteCount: needed)
        let availableText = formatter.string(fromByteCount: available)
        let floorText = formatter.string(fromByteCount: floor)
        // Show next-job cost, available capacity, and reserve as separate amounts.
        return "The next archive needs about \(neededText). Only "
          + "\(availableText) is free and Oxbow keeps \(floorText) in "
          + "reserve — downloads paused for this channel until there is "
          + "more room."
      case .contentRestricted:
        // Do not offer sign-in as a remedy; Oxbow queries anonymously.
        return """
          This channel's archives are subscriber-only, so Oxbow cannot \
          download them — automatic downloading is paused for it.
          """
      case .destinationUnreachable(let path):
        return "\(path) is not available — downloads paused for this channel "
          + "until the destination is reachable again."
      }
    }

    /// Identify destination demotions so the UI can avoid repeating an existing
    /// disconnected-volume notice.
    public var isDestinationUnreachable: Bool {
      if case .destinationUnreachable = self { return true }
      return false
    }
  }

  /// Require three restricted failures before treating the channel as restricted rather than
  /// individual archives.
  static let restrictedFailureThreshold = 3

  /// Infer restrictions from this channel's recent job failures, not unreliable Twitch
  /// metadata. Match FailureInterpreter.subscriberOnlySummary and recompute each sweep;
  /// clearing failure history removes this signal.
  public static func isContentRestricted(jobs: [Job]) -> Bool {
    let restricted = jobs.filter { job in
      job.steps.contains { step in
        if case .failed(let failure) = step.status {
          return failure.summary == FailureInterpreter.subscriberOnlySummary
        }
        return false
      }
    }
    return restricted.count >= restrictedFailureThreshold
  }

  public static func decide(
    watch: Watch, findings: [ChannelArchive], availableBytes: Int64,
    destinationExists: Bool, contentRestricted: Bool = false, floor: Int64
  ) -> Decision {
    guard watch.downloadsAutomatically else { return .notAutomatic }

    // Restrictions take precedence because destination recovery cannot resolve them.
    guard !contentRestricted else { return .demoted(.contentRestricted) }

    // Missing destination is more specific than insufficient capacity and prevents a reliable
    // volume check.
    guard destinationExists else {
      return .demoted(.destinationUnreachable(watch.settings.destinationPath))
    }
    // Skip recording/unknown archives for unattended work; later sweeps may find them recorded.
    let downloadable = findings.filter(\.isDownloadable)

    // Price each accepted prefix with BackfillEstimate: transient peak overhead is not linear
    // in archive count.
    var accepted: [ChannelArchive] = []
    for finding in downloadable {
      let candidate = accepted + [finding]
      let cost = BackfillEstimate(
        archives: candidate, cap: watch.settings.qualityCap, output: watch.settings.output
      ).bytes
      guard availableBytes - cost >= floor else { break }
      accepted = candidate
    }

    // If no archive fits, report a demotion with the first archive's cost rather than a quiet
    // empty submission.
    if accepted.isEmpty, let next = downloadable.first {
      let needed = BackfillEstimate(
        archives: [next], cap: watch.settings.qualityCap, output: watch.settings.output
      ).bytes
      return .demoted(.belowFloor(needed: needed, available: availableBytes, floor: floor))
    }

    // Partial fits leave remaining archives for later sweeps. The decision currently supplies
    // no explanation for that deferral.
    return .submit(accepted)
  }
}
