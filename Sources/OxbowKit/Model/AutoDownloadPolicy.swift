import Foundation

/// Whether a watch's unattended path may submit its findings, as one pure
/// decision. This is `docs/design/channel-watching.md` §5.2's unattended half
/// and §6.2 in full, expressed as code rather than prose.
///
/// Takes no store, no network and no clock — every argument is already
/// resolved by the caller, which is what makes every rule here decidable
/// without a window and testable without one either. `WatchPollPolicy` is
/// the sibling that answers the adjacent "is a sweep due" question in the
/// same shape.
public enum AutoDownloadPolicy {

  /// What a sweep should do with one watch's findings.
  ///
  /// Three cases, not two, because `.submit([])` and `.notAutomatic` mean
  /// different things a caller must not conflate: the first is "automatic
  /// downloading ran and found nothing new," the second is "automatic
  /// downloading did not run." Collapsing them would make a checkbox that is
  /// off indistinguishable from a channel that is quiet.
  public enum Decision: Equatable {
    case submit([ChannelArchive])
    case demoted(Reason)
    case notAutomatic
  }

  /// Why a watch's automatic downloading was demoted to notify-only this
  /// sweep. Each case carries what a person needs to be told, not just that
  /// something went wrong.
  public enum Reason: Equatable {
    case belowFloor(available: Int64, floor: Int64)
    case destinationUnreachable(String)

    /// The sentence a finding or a settings row shows for this reason.
    public var sentence: String {
      switch self {
      case .belowFloor(let available, let floor):
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let availableText = formatter.string(fromByteCount: available)
        let floorText = formatter.string(fromByteCount: floor)
        return "Only \(availableText) free, below the \(floorText) floor — "
          + "downloads paused for this channel until there is more room."
      case .destinationUnreachable(let path):
        return "\(path) is not available — downloads paused for this channel "
          + "until the destination is reachable again."
      }
    }
  }

  /// Decides what a watch's unattended sweep should do with what it found.
  ///
  /// - Parameters:
  ///   - watch: The watch being swept, for its `downloadsAutomatically` flag.
  ///   - findings: Archives this sweep found that the watch has not acted on
  ///     yet (`Watch.findings(in:)`), in any order.
  ///   - availableBytes: Free space on **the destination's own volume**,
  ///     already resolved by the caller — not the boot volume's. A channel
  ///     writing to `/Volumes/Archive` is asking whether *that* disk has
  ///     room, per §6.2; passing the wrong volume's figure here silently
  ///     answers the wrong question and this function has no way to catch it.
  ///   - destinationExists: Whether `watch.settings.destination` currently
  ///     resolves to something on disk, already checked by the caller.
  ///   - floor: The free-space floor to check `availableBytes` against —
  ///     `Preferences.freeSpaceFloor` in production, passed in rather than
  ///     read here so this stays clockless and storeless.
  /// - Returns: `.notAutomatic` if the watch has automatic downloading off;
  ///   otherwise `.demoted` if the destination is unreachable or the volume
  ///   is at or below the floor; otherwise `.submit` of just the findings
  ///   that are safe to queue unattended.
  ///
  /// **Demotion here is per-call, not per-watch state.** Nothing is
  /// recorded anywhere — the next sweep calls this again with whatever the
  /// world looks like *then*, so a drive that was unplugged and is now back
  /// submits normally again with no recovery step required. A demotion that
  /// stuck would be indistinguishable from the user having turned the
  /// checkbox off, which is exactly the confusion §6.2 rules out.
  public static func decide(
    watch: Watch, findings: [ChannelArchive], availableBytes: Int64,
    destinationExists: Bool, floor: Int64
  ) -> Decision {
    guard watch.downloadsAutomatically else { return .notAutomatic }

    // Destination first: it is the more specific, more actionable fact when
    // both apply (§6.2's account of the two causes converging on one
    // behaviour), and a missing destination makes the floor unanswerable
    // anyway — there is no volume to have asked about.
    guard destinationExists else {
      return .demoted(.destinationUnreachable(watch.settings.destinationPath))
    }
    guard availableBytes >= floor else {
      return .demoted(.belowFloor(available: availableBytes, floor: floor))
    }

    // §5.2: a RECORDING broadcast is the newest item and exactly what a poll
    // finds first; it is skipped here and picked up once it has ended.
    return .submit(findings.filter(\.isDownloadable))
  }
}
