import Foundation

/// One video's facts, kept so they outlive the video.
///
/// **Every field but `id` is optional, and that is the design rather than
/// laziness.** Two sources write this record and neither is complete: a sweep
/// knows a video's title, category and thumbnail but never its renditions, and
/// a submission knows its renditions and payload but never when it was last
/// seen on Twitch (`docs/design/video-record.md` §7). A required field would
/// force one of them to invent a value.
///
/// **Video facts only.** `skipped` and `ignored` are statements about a
/// person's relationship to a *channel*, not properties of a video, so they
/// live in `WatchState` and not here (§3.2). This is what lets Get Info render
/// a hand-pasted video and a watched channel's archive identically.
///
/// `durationSeconds` rather than `Duration`: this is persisted, and `Duration`
/// encodes as an opaque pair of attosecond halves. The same reasoning
/// `Watch.Settings.destinationPath` gives for being a `String`.
public struct VideoRecord: Equatable, Sendable, Codable {

  /// Twitch's video id. The join key to everything, and the one field that is
  /// never absent.
  public var id: String

  public var login: String?

  /// The channel's name as Twitch presents it — `VideoInfo.streamer`, which is
  /// `video.owner.displayName`.
  ///
  /// **Stored rather than derived, because it cannot be derived.**
  /// `video-record.md` §3.4 is explicit that a display name and a login are
  /// two different strings and neither follows from the other: a display name
  /// can be Japanese while the login is ASCII. Without this field a remembered
  /// card had to fall back to the login, so an expired VOD read `seecatplay`
  /// where a live one read `SeeCatPlay` — a visible difference between a card
  /// the record drew and the same card drawn from Twitch, which §4.1 of that
  /// document says must not exist.
  ///
  /// Optional like every other field here: a sweep learns it from the watch,
  /// a submission from the payload, and a record written before this existed
  /// has none.
  public var displayName: String?
  public var title: String?
  public var durationSeconds: Int?
  public var publishedAt: Date?
  public var qualities: [StreamQuality]
  public var categoryName: String?
  public var thumbnailURLs: [URL]

  /// Where the download landed. A `String` because it is persisted.
  ///
  /// **A claim, not an answer.** Whatever renders a row asks the disk about
  /// this path rather than trusting it, because deleting a download is a
  /// thing people do and the record never hears about it — the filesystem is
  /// the authority (`docs/design/video-record.md` §5).
  public var deliveredPath: String?

  /// Stamped by the sweep. Absent from the newest sweep means expired.
  public var lastSeenOnTwitch: Date?

  /// Which helper produced the stored raw payload, or nil when there is none.
  ///
  /// **The stamp is load-bearing** (§3.3): `--format Raw`'s shape is not a
  /// stable upstream contract, so a payload is only re-parseable later if a
  /// future parser can tell which dialect it is in.
  public var payloadHelperVersion: String?

  public init(
    id: String,
    login: String? = nil,
    displayName: String? = nil,
    title: String? = nil,
    durationSeconds: Int? = nil,
    publishedAt: Date? = nil,
    qualities: [StreamQuality] = [],
    categoryName: String? = nil,
    thumbnailURLs: [URL] = [],
    deliveredPath: String? = nil,
    lastSeenOnTwitch: Date? = nil,
    payloadHelperVersion: String? = nil)
  {
    self.id = id
    self.login = login
    self.displayName = displayName
    self.title = title
    self.durationSeconds = durationSeconds
    self.publishedAt = publishedAt
    self.qualities = qualities
    self.categoryName = categoryName
    self.thumbnailURLs = thumbnailURLs
    self.deliveredPath = deliveredPath
    self.lastSeenOnTwitch = lastSeenOnTwitch
    self.payloadHelperVersion = payloadHelperVersion
  }

  /// What this record can still say about the video, in the shape the rest of
  /// the app already renders.
  ///
  /// **The answer when Twitch no longer has one.** Get Info re-fetches on every
  /// open, and for an expired video that fetch fails — leaving a card with a
  /// grey rectangle and whatever title the job happened to store. This is the
  /// whole reason the record exists: the metadata was fetched once, while the
  /// video still existed, and kept.
  ///
  /// Nil without a title, which is the one field a card cannot stand in for.
  /// A row migrated from the old bare-id seen-set has no title and never will
  /// (`docs/design/video-record.md` §8), so there is genuinely nothing to show.
  ///
  /// **`streamer` falls back to the login**, because that is the only name a
  /// record holds — display names live on a `Watch`, and a video pasted by
  /// hand belongs to no watch. So a remembered card may read `wheelyf` where a
  /// live one reads `WheelyF`. Storing the display name too would fix it and
  /// is not worth a schema change on its own.
  public func remembered() -> VideoInfo? {
    guard let title else { return nil }
    return VideoInfo(
      // The display name when the record kept one, the login when it did not.
      // Before `displayName` existed this was always the login, which is what
      // made a remembered card visibly different from a live one.
      streamer: displayName ?? login ?? "",
      login: login,
      title: title,
      createdAt: publishedAt ?? .distantPast,
      duration: .seconds(durationSeconds ?? 0),
      qualities: qualities,
      thumbnailURLs: thumbnailURLs)
  }

  /// This record updated with everything `other` knows and nothing it does not.
  ///
  /// **Additive, never destructive.** An incoming record's `nil` means "I did
  /// not learn this", never "this is now unknown" — the two writers each see
  /// half the picture, so a plain overwrite would make the last one to run
  /// erase the other's half.
  ///
  /// Two fields depart from that, each for a reason:
  ///
  /// - `lastSeenOnTwitch` takes the **later** of the two. It is a timestamp of
  ///   the most recent sighting rather than a fact about the video, so newer
  ///   genuinely is better.
  /// - `thumbnailURLs` takes the **larger** set. A VOD's `info` payload carries
  ///   four sampled frames and a sweep carries one (§6.1); merging by "non-empty
  ///   wins" would let a later sweep demote a filmstrip back to a still.
  public func merging(_ other: VideoRecord) -> VideoRecord {
    // A mismatch is a programmer error upstream of here. Returning self keeps
    // it from quietly producing a record that is half one video and half
    // another, which is the failure that would be hardest to notice.
    guard other.id == id else { return self }

    var merged = self
    merged.login = other.login ?? login
    merged.displayName = other.displayName ?? displayName
    merged.title = other.title ?? title
    merged.durationSeconds = other.durationSeconds ?? durationSeconds
    merged.publishedAt = other.publishedAt ?? publishedAt
    merged.categoryName = other.categoryName ?? categoryName
    merged.deliveredPath = other.deliveredPath ?? deliveredPath
    merged.payloadHelperVersion = other.payloadHelperVersion ?? payloadHelperVersion
    merged.qualities = other.qualities.isEmpty ? qualities : other.qualities
    merged.thumbnailURLs = other.thumbnailURLs.count > thumbnailURLs.count
      ? other.thumbnailURLs
      : thumbnailURLs

    switch (lastSeenOnTwitch, other.lastSeenOnTwitch) {
    case (let mine?, let theirs?): merged.lastSeenOnTwitch = max(mine, theirs)
    case (nil, let theirs?): merged.lastSeenOnTwitch = theirs
    case (let mine?, nil): merged.lastSeenOnTwitch = mine
    case (nil, nil): merged.lastSeenOnTwitch = nil
    }

    return merged
  }
}

/// Where one archive stands with the channel that produced it.
///
/// **These are not properties of a video.** `skipped` means "this existed
/// before you started watching this channel" and `ignored` means "you
/// dismissed it from that channel's list" — both are statements about a
/// relationship, and a video pasted by hand has neither. That is why they live
/// here rather than on `VideoRecord` (`docs/design/video-record.md` §3.2).
///
/// Defined in `docs/design/channel-history.md` §3.1 and carried forward
/// unchanged.
public enum WatchState: String, Equatable, Sendable, Codable, CaseIterable {
  /// On Twitch, not acted on.
  case new
  /// Existed before you started watching. What "Only new" seeding produces.
  case skipped
  /// Submitted to the queue.
  case queued
  /// Its job finished, and `deliveredPath` is set.
  case downloaded
  /// You dismissed it.
  case ignored
  /// Its job failed. Actionable again.
  case failed

  /// Whether a row in this state belongs in a channel's default view.
  ///
  /// §5.1 of `docs/design/video-record.md`: by default a channel shows the
  /// three things a person actually acts on — what you have, what is being
  /// fetched, and what you could still get. `skipped` and `ignored` are the
  /// two states that mean "you already decided about this", and §5.2 keeps
  /// them behind a filter so a channel watched for a year does not become
  /// mostly headstones. A backfilled channel is the case that makes this
  /// matter: seeding one with "Only new" can mark a hundred archives skipped
  /// at once.
  ///
  /// `failed` is visible on purpose. §6.3 of `channel-watching.md` leaves a
  /// failed download actionable, so hiding it would strand the one row a
  /// person most likely wants to retry.
  ///
  /// **An archive with no recorded state at all is visible**, and that is not
  /// this property's business — a missing state means the sweep has seen the
  /// archive and nothing has acted on it, which is `new` by another name. The
  /// caller treats nil as visible rather than defaulting a state it has no
  /// evidence for.
  public var isVisibleByDefault: Bool {
    switch self {
    case .new, .queued, .downloaded, .failed: true
    case .skipped, .ignored: false
    }
  }

  /// Whether a watch should treat this archive as already handled.
  ///
  /// **This is what `seen` used to be**, and the definition is unchanged:
  /// everything except `new` and `failed`. Storing both a state and a seen-set
  /// is the drift that produced every ordering bug in this feature, so the set
  /// is derived and never written.
  public var countsAsSeen: Bool {
    switch self {
    case .new, .failed: false
    case .skipped, .queued, .downloaded, .ignored: true
    }
  }
}

/// Every video Oxbow has touched, and where each stands with its channel.
///
/// Two dictionaries rather than one, because §3.2's two halves are genuinely
/// different things: `videos` is what Get Info reads and is written for
/// everything, `watchStates` is written only for videos belonging to a watched
/// channel.
public struct VideoLibrary: Equatable, Sendable, Codable {
  public var videos: [String: VideoRecord]
  public var watchStates: [String: WatchState]

  public init(videos: [String: VideoRecord] = [:], watchStates: [String: WatchState] = [:]) {
    self.videos = videos
    self.watchStates = watchStates
  }

  /// Adds or merges one video's facts. Never destructive — see
  /// `VideoRecord.merging(_:)`.
  public mutating func record(_ incoming: VideoRecord) {
    videos[incoming.id] = videos[incoming.id]?.merging(incoming) ?? incoming
  }

  public mutating func setState(_ state: WatchState, for id: String) {
    watchStates[id] = state
  }

  /// The archive ids `login`'s watch should treat as already handled.
  ///
  /// Replaces `Watch.seen` as the answer to that question. Scoped by login so
  /// two channels cannot mark each other's archives.
  public func seenIDs(forLogin login: String) -> Set<String> {
    Set(
      watchStates
        .filter { $0.value.countsAsSeen && videos[$0.key]?.login == login }
        .keys)
  }

  /// Applies §3.6 when a watch is removed.
  ///
  /// Drops that channel's watch state entirely, and drops its video rows
  /// **except** those you have something to show for — a delivered file, or a
  /// job still in the queue. Those survive because they are exactly the rows
  /// Get Info exists to render, and because a row that survives is what makes
  /// re-adding the channel light up with what you already have.
  ///
  /// This is also the only thing that ever makes an image unreferenced. With
  /// nothing removed, `referencedImageURLs()` could only ever grow and the
  /// purge would have nothing to find.
  public mutating func removeWatch(login: String, keepingVideosWithJobs jobbed: Set<String>) {
    // Materialised rather than a lazy filter view: the loop below mutates
    // `videos`, and a lazy view over it would be iterating the thing it is
    // changing.
    let mine = Array(videos.filter { $0.value.login == login }.keys)

    for id in mine {
      watchStates.removeValue(forKey: id)
      let hasFile = videos[id]?.deliveredPath != nil
      if !hasFile && !jobbed.contains(id) {
        videos.removeValue(forKey: id)
      }
    }
  }

  /// Every image URL a surviving row still names — the record's half of the
  /// purge keep-set, and only that half.
  ///
  /// The image store also holds watched channels' avatars, which no row ever
  /// names and which this type has no way of knowing about: a record does not
  /// know what is being watched. A caller that purges against this set alone
  /// deletes every avatar in the store. The union with the surviving watches'
  /// avatars belongs to whoever holds both — see
  /// `docs/design/video-record.md` §3.6.
  public func referencedImageURLs() -> Set<URL> {
    Set(videos.values.flatMap(\.thumbnailURLs))
  }
}
