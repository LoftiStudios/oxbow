import Foundation
import OxbowKit

/// Resolve the inspector subject from the visible destination and selections before building
/// the view.
enum InspectorSubject: Equatable {
  case nothing
  case one(InfoTarget)
  case many(MultiSelection)
}

/// Queue multi-selection; Watching destinations support single selection only.
struct MultiSelection: Equatable {
  /// The full selection count, independent of the stack's four visible layers.
  var count: Int

  var queued: Int = 0
  var running: Int = 0
  var done: Int = 0
  var failed: Int = 0
  var cancelled: Int = 0

  /// Nil if any selected job lacks the duration or rendition needed for an estimate. Never a
  /// partial sum.
  var estimatedBytes: Int64?

  /// Full selection in arrival order, oldest first, so new selections land on top.
  /// SelectionStack displays four depths; missing thumbnails use placeholders.
  var cards: [StackCard] = []

  /// Distinct channels in queue order, preferring display names and falling back to logins.
  /// Omit only records with neither.
  var channels: [String] = []
}

/// Job identity keeps insertion and removal animations attached to the correct card.
struct StackCard: Identifiable, Equatable {
  let id: JobID
  let url: URL?
}

extension InspectorSubject {

  static func resolve(
    destination: SidebarItem?,
    queueSelection: Set<JobID>,
    watchingSelection: WatchingModel.Row.ID?,
    sections: [WatchingModel.Section],
    library: VideoLibrary,
    /// The queue selection in the order it was made, oldest first — see
    /// `MultiSelection.cards`. Only the stack reads it; counts and the
    /// estimate stay queue-ordered.
    arrivals: [JobID] = [],
    jobs: [Job]
  ) -> InspectorSubject {
    switch destination {
    case .watching:
      // The inbox is cross-channel, so its rows are every section's `rows`.
      return watching(watchingSelection, in: sections.flatMap(\.rows))
    case .channel(let login):
      // A channel destination shows `allRows`, so a row the inbox holds back
      // is still selectable there.
      guard let section = sections.first(where: { $0.login == login }) else {
        return .nothing
      }
      return watching(watchingSelection, in: section.allRows)
    case .queue, .none:
      // Nil selects the queue, matching QueueView's detail switch.
      break
    }

    // Filter jobs to retain stable queue order; the selection Set is unordered.
    let selected = jobs.filter { queueSelection.contains($0.id) }

    switch selected.count {
    case 0:
      return .nothing
    case 1:
      return .one(target(for: selected[0]))
    default:
      var many = MultiSelection(count: selected.count)
      for job in selected {
        switch job.status {
        case .queued: many.queued += 1
        case .running: many.running += 1
        case .done: many.done += 1
        case .failed: many.failed += 1
        case .cancelled: many.cancelled += 1
        }
      }
      many.estimatedBytes = estimate(selected, library: library)
      many.cards = stack(arrivals: arrivals, jobs: jobs, library: library)
      many.channels = channels(selected, library: library)
      return .many(many)
    }
  }

  /// Estimate delivered bytes, excluding transient workspace usage. Require every job's
  /// duration and actual rendition; return nil if any is missing.
  private static func estimate(_ jobs: [Job], library: VideoLibrary) -> Int64? {
    var sum = Int64(0)
    for job in jobs {
      guard let request = videoRequest(in: job),
            let record = library.videos[request.videoID],
            let seconds = record.durationSeconds,
            let quality = record.qualities.first(where: { $0.name == request.quality })
      else { return nil }

      // A trimmed job downloads the span, not the video. `trimEnd` unset runs
      // to the end; `trimStart` unset starts at zero.
      let whole = Duration.seconds(seconds)
      let start = request.trimStart ?? .zero
      let end = request.trimEnd ?? whole
      let span = end - start

      sum += SpaceEstimate(
        quality: quality,
        duration: span,
        composite: compositeGeometry(in: job, quality: quality)).delivered
    }
    return sum
  }

  /// All selected cards, oldest first, including those behind the visible fan.
  private static func stack(
    arrivals: [JobID], jobs: [Job], library: VideoLibrary
  ) -> [StackCard] {
    let byID = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return arrivals.map { id in
      guard let media = byID[id]?.mediaIdentifier else { return StackCard(id: id, url: nil) }
      return StackCard(id: id, url: library.videos[media]?.thumbnailURLs.first)
    }
  }

  /// Distinct channels in stable queue order, since the visible list may be truncated.
  private static func channels(_ jobs: [Job], library: VideoLibrary) -> [String] {
    var seen = Set<String>()
    var names: [String] = []
    for job in jobs {
      guard let media = job.mediaIdentifier,
            let record = library.videos[media],
            let name = record.displayName ?? record.login,
            seen.insert(name).inserted
      else { continue }
      names.append(name)
    }
    return names
  }

  /// Video-download request, if present. This estimate path cannot price clip-only or chat-only
  /// jobs.
  private static func videoRequest(in job: Job) -> VideoRequest? {
    for step in job.steps {
      if case .downloadVideo(let request) = step.kind { return request }
    }
    return nil
  }

  /// Composite geometry, or nil to exclude render/composite costs from a video-only estimate.
  private static func compositeGeometry(
    in job: Job, quality: StreamQuality
  ) -> CompositeGeometry? {
    let composites = job.steps.contains { step in
      if case .composite = step.kind { return true }
      return false
    }
    return composites ? CompositeGeometry(quality: quality) : nil
  }

  /// Resolve only against visible archives; Watching is single-select.
  private static func watching(
    _ selection: WatchingModel.Row.ID?, in rows: [WatchingModel.Row]
  ) -> InspectorSubject {
    guard let selection, rows.contains(where: { $0.id == selection }) else {
      return .nothing
    }
    return .one(.video(selection))
  }

  /// Use video identity where available, otherwise retain access through JobID.
  static func target(for job: Job) -> InfoTarget {
    if let media = job.mediaIdentifier { return .video(media) }
    return .job(job.id)
  }
}
