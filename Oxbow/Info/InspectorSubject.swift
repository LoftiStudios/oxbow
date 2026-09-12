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
  /// The full selection count, independent of the stack's four visible layers.
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

  /// All selected cards, oldest first — so the last one is on top.
  ///
  /// **Arrival order, not queue order.** §5.1 said queue order and gave the
  /// right reason — a `Set` has none, so a fan rendered straight from one
  /// would reshuffle every rebuild — but drew the wrong conclusion. Arrival
  /// order is *remembered*, so it is just as stable, and it is the only order
  /// that lets the card you just added be the card that lands on top.
  ///
  /// Queue order made extending a selection upward put the same card on top
  /// every time, and made the first-selected one vanish outright once five
  /// were picked.
  ///
  /// The full selection; SelectionStack limits the fan to four visible depths.
  /// A nil `url` is a job whose video has no thumbnail and
  /// draws a placeholder tile, so the fan keeps its shape.
  var cards: [StackCard] = []

  /// Which channels the selection spans, in queue order, de-duplicated.
  ///
  /// **Display names where the record kept one, the login where it did not.**
  /// `video-record.md` §3.4: the two are different strings and neither follows
  /// from the other, which is why `VideoRecord.displayName` exists — without
  /// it this line read `leighxp, wheelyf`.
  ///
  /// **A record with neither is the only thing omitted.** An earlier version
  /// dropped every record that had no display name, on the theory that one
  /// lowercase entry among proper names would read as a bug. That was wrong
  /// twice: plenty of Twitch display names *are* lowercase, and a line naming
  /// the channels that silently drops one is the same "partial answer
  /// presented as complete" this file refuses for `estimatedBytes`. Observed
  /// naming two of three channels, with the third missing only because it was
  /// never watched.
  var channels: [String] = []
}

/// One card in the selection stack, identified by the job it stands for.
///
/// **Identified, not just positional.** A stable id per card is what lets
/// SwiftUI animate an insertion or a removal as *that card* arriving or
/// leaving, rather than redrawing a pile of a different length.
struct StackCard: Identifiable, Equatable {
  let id: JobID
  let url: URL?
}

extension InspectorSubject {

  /// **Deliberately takes values, not a view.** §3.3: this is the whole
  /// behavioural surface of the feature, and it stays testable only while it
  /// stays a function of its arguments.
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
      // **nil is the queue**, matching `QueueView`'s detail switch, which
      // renders the queue for `case .none`. The inspector has to agree with
      // the pane on screen; blanking while a selected queue row sits beside it
      // would be the pane disagreeing with itself.
      break
    }

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
      many.estimatedBytes = estimate(selected, library: library)
      many.cards = stack(arrivals: arrivals, jobs: jobs, library: library)
      many.channels = channels(selected, library: library)
      return .many(many)
    }
  }

  /// What these downloads will occupy when they land, or **nil**.
  ///
  /// **Nil the moment any one of them cannot be priced** — §5.3. Not a
  /// smaller number: a total that silently drops two of five looks complete
  /// and is not, and a disk figure is precisely the kind people act on. The
  /// same refusal `twitch-channel-api.md` §5.1 makes about `totalCount`,
  /// `VolumeSpace.nearestExisting` makes about "could not ask", and
  /// `ChannelCard` makes about naming one volume rather than summarising
  /// across several.
  ///
  /// **Priced at the rendition the job is actually fetching, not a nominal
  /// one.** A `Job` carries no duration but its download step does carry the
  /// quality string it was built with, and `VideoRecord.qualities` holds the
  /// `StreamQuality` — with a real measured bitrate — that string names. Both
  /// halves have to be present: a record with no duration, or one that has
  /// never heard of the rendition, makes the whole selection unpriceable
  /// rather than approximately priced.
  ///
  /// `delivered` rather than `total`: the question is what these will occupy
  /// once finished, not the transient peak while a composite is being written.
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

  /// The distinct channels the selection spans, first-seen order.
  ///
  /// Queue order again rather than the selection's, for §5.1's reason — the
  /// list is truncated on screen, so which names survive the truncation has to
  /// be stable between rebuilds.
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

  /// The job's video download, when it has one. A chat-only or clip job has
  /// none, and is therefore unpriceable by this route.
  private static func videoRequest(in job: Job) -> VideoRequest? {
    for step in job.steps {
      if case .downloadVideo(let request) = step.kind { return request }
    }
    return nil
  }

  /// The composite's geometry when the job actually composites, else nil —
  /// which is what zeroes `SpaceEstimate`'s render and composite terms, so a
  /// video-only job is priced as the one file it delivers.
  private static func compositeGeometry(
    in job: Job, quality: StreamQuality
  ) -> CompositeGeometry? {
    let composites = job.steps.contains { step in
      if case .composite = step.kind { return true }
      return false
    }
    return composites ? CompositeGeometry(quality: quality) : nil
  }

  /// One archive, if the selected id names a row that is actually showing.
  ///
  /// **A selection from another destination is not an error.** §3.2: one piece
  /// of state is resolved against whatever is visible, so selecting a row in
  /// LeighXP and switching to AvaBamby simply matches nothing — no reset step,
  /// and no chance of resolving to the wrong row, because archive ids are
  /// unique across Twitch.
  ///
  /// **Never `.many`.** Both Watching destinations are single-select, and §3.3
  /// wants that encoded rather than implied.
  private static func watching(
    _ selection: WatchingModel.Row.ID?, in rows: [WatchingModel.Row]
  ) -> InspectorSubject {
    guard let selection, rows.contains(where: { $0.id == selection }) else {
      return .nothing
    }
    // An archive id *is* a video id — `video-record.md` §3.1's "join key to
    // everything", and why this design costs so little.
    return .one(.video(selection))
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
