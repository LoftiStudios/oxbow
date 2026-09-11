import Foundation
import OxbowKit

/// What the inspector is currently about.
///
/// `docs/design/inspector.md` §3.3. Resolved before any view is built, from
/// the visible destination and the selections, so the pane switches on an
/// answer rather than deriving one — which is what lets the whole behaviour
/// be tested without a window.
enum InspectorSubject: Equatable {
  case nothing
  case one(InfoTarget)
  case many(MultiSelection)
}

/// Everything §5 renders for a multi-selection.
///
/// **Only the queue can produce one.** Both Watching destinations are
/// single-select, and encoding that here rather than leaving it implicit means
/// a future multi-select over there has to come back to the design instead of
/// inheriting this by accident.
struct MultiSelection: Equatable {
  /// The true count, which is deliberately *not* `thumbnails.count` — that one
  /// is capped at four (§5.1) while this one keeps telling the truth.
  var count: Int

  var queued: Int = 0
  var running: Int = 0
  var done: Int = 0
  var failed: Int = 0
  var cancelled: Int = 0

  /// **Nil when any selected job could not be priced** — §5.3. Not zero, and
  /// never a partial sum: a `Job` carries no duration, so pricing goes through
  /// `VideoRecord.durationSeconds`, which is optional and can be missing. A
  /// total that silently drops two of five is the mistake `totalCount`,
  /// `nearestExisting` and `ChannelCard`'s volume notice each already refuse.
  ///
  /// Filled by slice D; always nil before then, which is the same value it
  /// carries whenever a selection cannot be fully priced.
  var estimatedBytes: Int64?

  /// Queue order, capped at four. A nil entry is a job whose video has no
  /// thumbnail and draws a placeholder tile, keeping the stack's shape rather
  /// than collapsing it. Filled by slice E.
  var thumbnails: [URL?] = []
}

extension InspectorSubject {

  /// **Deliberately takes values, not a view.** §3.3: this is the whole
  /// behavioural surface of the feature, and it stays testable only while it
  /// stays a function of its arguments.
  static func resolve(
    destination: SidebarItem?,
    queueSelection: Set<JobID>,
    jobs: [Job]
  ) -> InspectorSubject {
    // **Not a fall-through to the queue's selection.** Slice C replaces this
    // with the Watching branches; until then a channel destination resolves to
    // nothing, because a pane showing a queue row while you are looking at a
    // channel is worse than a pane showing nothing at all.
    guard destination == .queue else { return .nothing }

    // **Queue order, not selection order.** `queueSelection` is a `Set` and a
    // `Set` has none — filtering the jobs preserves the order on screen, where
    // iterating the selection would shuffle between rebuilds. Nothing depends
    // on this yet; slice E's stack will, and establishing it here means that
    // slice inherits a correct order rather than adding one late (§5.1).
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
      return .many(many)
    }
  }

  /// The video when there is one, the job when there is not.
  ///
  /// `video-record.md` §4.2's two-case key, reused whole: a job carrying no
  /// video, clip or chat request with an id stays addressable rather than
  /// becoming the one row nothing can be opened on.
  static func target(for job: Job) -> InfoTarget {
    if let media = job.mediaIdentifier { return .video(media) }
    return .job(job.id)
  }
}
