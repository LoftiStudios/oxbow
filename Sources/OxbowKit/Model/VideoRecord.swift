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
  public var title: String?
  public var durationSeconds: Int?
  public var publishedAt: Date?
  public var qualities: [StreamQuality]
  public var categoryName: String?
  public var thumbnailURLs: [URL]

  /// Where the download landed. A `String` because it is persisted; the
  /// filesystem check that reads it lives in stage 3b.
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
