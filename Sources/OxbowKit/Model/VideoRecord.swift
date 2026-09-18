import Foundation

/// Persisted video facts, separate from channel watch state. Fields other than ID are optional
/// because sweeps and submissions provide different subsets. Duration is stored as seconds
/// rather than `Duration`'s opaque Codable representation.
public struct VideoRecord: Equatable, Sendable, Codable {

  /// Twitch's video id. The join key to everything, and the one field that is
  /// never absent.
  public var id: String

  public var login: String?

  /// Display name from Twitch, stored separately from login because it cannot be derived.
  /// Optional for older records and incomplete metadata.
  public var displayName: String?
  public var title: String?
  public var durationSeconds: Int?
  public var publishedAt: Date?
  public var qualities: [StreamQuality]
  public var categoryName: String?
  public var thumbnailURLs: [URL]

  /// Recorded delivery path. Check the filesystem before showing availability: files may have
  /// been moved or deleted externally.
  public var deliveredPath: String?

  /// Stamped by the sweep. Absent from the newest sweep means expired.
  public var lastSeenOnTwitch: Date?

  /// Helper version that produced the raw payload. Needed to interpret stored data if
  /// upstream's raw format changes.
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

  /// Reconstructs a card from retained facts when Twitch is unavailable. Requires a title; uses
  /// the stored display name, falling back to login.
  public func remembered() -> VideoInfo? {
    guard let title else { return nil }
    return VideoInfo(
      streamer: displayName ?? login ?? "",
      login: login,
      title: title,
      createdAt: publishedAt ?? .distantPast,
      duration: .seconds(durationSeconds ?? 0),
      qualities: qualities,
      thumbnailURLs: thumbnailURLs)
  }

  /// Merges known facts without clearing fields for incoming nils. Keeps the later
  /// `lastSeenOnTwitch` and the larger thumbnail collection, so a one-image sweep cannot
  /// replace a four-frame preview.
  public func merging(_ other: VideoRecord) -> VideoRecord {
    // Do not combine facts belonging to different videos.
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

/// An archive's state within a watched channel. Skipped and ignored describe that relationship,
/// not the video's metadata.
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

  /// Default channel visibility excludes skipped/ignored archives but includes failed downloads
  /// for retry. Callers treat missing state as visible.
  public var isVisibleByDefault: Bool {
    switch self {
    case .new, .queued, .downloaded, .failed: true
    case .skipped, .ignored: false
    }
  }

  /// Handled means any state except new or failed. Derive seen IDs from this state instead of
  /// maintaining a second set.
  public var countsAsSeen: Bool {
    switch self {
    case .new, .failed: false
    case .skipped, .queued, .downloaded, .ignored: true
    }
  }
}

/// Video facts for all known videos, plus states for those associated with watched channels.
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

  /// Handled archive IDs scoped by channel login.
  public func seenIDs(forLogin login: String) -> Set<String> {
    Set(
      watchStates
        .filter { $0.value.countsAsSeen && videos[$0.key]?.login == login }
        .keys)
  }

  /// Removes a channel's watch states and unneeded video records. Retains records with
  /// delivered files or queued jobs. Removed records may leave cached images eligible for
  /// purging.
  public mutating func removeWatch(login: String, keepingVideosWithJobs jobbed: Set<String>) {
    // Materialize keys before mutating the dictionary.
    let mine = Array(videos.filter { $0.value.login == login }.keys)

    for id in mine {
      watchStates.removeValue(forKey: id)
      let hasFile = videos[id]?.deliveredPath != nil
      if !hasFile && !jobbed.contains(id) {
        videos.removeValue(forKey: id)
      }
    }
  }

  /// Image references from video records only. Union with surviving watches' avatars before
  /// purging, or every avatar will be deleted.
  public func referencedImageURLs() -> Set<URL> {
    Set(videos.values.flatMap(\.thumbnailURLs))
  }
}
