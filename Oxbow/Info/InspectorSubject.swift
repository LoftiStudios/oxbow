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
  /// than collapsing it.
  var thumbnails: [URL?] = []

  /// Which channels the selection spans, in queue order, de-duplicated.
  ///
  /// **Display names, which is why `VideoRecord.displayName` had to exist.**
  /// Before it, this line would have read `leighxp, wheelyf` — the logins,
  /// which `video-record.md` §3.4 is clear are a different string from the
  /// name a person recognises. A record that has never learned a name
  /// contributes nothing rather than its login: one lowercase entry in a list
  /// of proper names reads as a bug, and the list is already truncated.
  var channels: [String] = []
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
      many.thumbnails = stack(selected, library: library)
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

  /// The first four selected videos' thumbnails, in queue order.
  ///
  /// **Queue order, never the selection's** — §5.1. `selected` is already
  /// filtered out of `jobs` rather than iterated out of the `Set`, so this
  /// inherits a stable order instead of reshuffling on every rebuild. That is
  /// a glitch that survives review because nobody scrolls the same list twice.
  ///
  /// **Capped at four, and a miss stays as `nil`.** A fan of forty is a
  /// smear, and `count` keeps the true number. A job whose video has no record
  /// or no thumbnail holds its place so the stack keeps its shape — the same
  /// call `VideoThumbnail` makes when Twitch has no preview, rather than
  /// quietly drawing a shorter fan that misstates how many are selected.
  private static func stack(_ jobs: [Job], library: VideoLibrary) -> [URL?] {
    jobs.prefix(4).map { job in
      guard let media = job.mediaIdentifier else { return nil }
      return library.videos[media]?.thumbnailURLs.first
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
            let name = library.videos[media]?.displayName,
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
