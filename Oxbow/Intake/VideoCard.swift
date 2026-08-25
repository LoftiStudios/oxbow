import SwiftUI
import OxbowKit

/// The pasted link, made recognisable: the video's own preview image beside
/// its title, who streamed it, and when.
///
/// **The card occupies its space before it has anything to put in it.** The
/// metadata fetch is a network round trip, so a card that only appeared once
/// it returned made the window jump by its own height at an unpredictable
/// moment. `.loading` draws the same layout at the same size with placeholder
/// text, and the real values replace it in place. The thumbnail well inside it
/// is fixed for the same reason.
struct VideoCard: View {
  enum Content {
    /// Metadata is on its way. Same layout, redacted.
    case loading
    case loaded(VideoInfo)
    /// The fetch failed, or there is nothing to fetch. The card keeps its
    /// place and says what it can — for a queued job that is its title, which
    /// is derived from the video's own metadata anyway.
    case unavailable(title: String)
  }

  let content: Content

  init(_ content: Content) {
    self.content = content
  }

  init(info: VideoInfo) {
    self.content = .loaded(info)
  }

  var body: some View {
    switch content {
    case .loading:
      // Deliberately plausible lengths rather than "…": a placeholder bar the
      // width of a real title is what makes the swap read as filling in
      // rather than as growing.
      card(
        title: "A stream title of roughly this length",
        streamer: "Streamer",
        details: "Aug 00, 0000 · 00:00",
        thumbnail: .loading)
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading video details")

    case .loaded(let info):
      card(
        title: info.title,
        streamer: info.streamer,
        details: details(of: info),
        thumbnail: .url(info.thumbnailURL))

    case .unavailable(let title):
      card(title: title, streamer: nil, details: nil, thumbnail: .unavailable)
    }
  }

  private func card(
    title: String,
    streamer: String?,
    details: String?,
    thumbnail: VideoThumbnail.Source)
    -> some View
  {
    HStack(alignment: .top, spacing: 12) {
      VideoThumbnail(source: thumbnail)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.headline)
          .lineLimit(2)
          // Titles are user-written and often long; two lines that wrap beat
          // one line that truncates the part that identifies the stream.
          .fixedSize(horizontal: false, vertical: true)

        if let streamer {
          Text(streamer)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        if let details {
          Text(details)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: 0)
    }
    // A floor, not a fixed height: a two-line title is taller, but the card
    // must never be shorter than the thumbnail it contains, or the loading
    // and loaded states would still differ in height.
    .frame(minHeight: VideoThumbnail.height, alignment: .top)
    .accessibilityElement(children: .combine)
  }

  /// When it was streamed, and how long it runs.
  private func details(of info: VideoInfo) -> String {
    let date = info.createdAt.formatted(date: .abbreviated, time: .omitted)
    return "\(date) · \(Self.length(of: info.duration))"
  }

  /// `16:31` for a clip or a short VOD, `3:12:04` for a long one — the same
  /// shape a video player shows, rather than a leading `0:` nobody reads.
  private static func length(of duration: Duration) -> String {
    duration.components.seconds >= 3600
      ? duration.formatted(.time(pattern: .hourMinuteSecond))
      : duration.formatted(.time(pattern: .minuteSecond))
  }
}

/// The preview image at a fixed 16:9 frame, in every state it can be in.
///
/// **160x90 is a ceiling, not a preference.** A VOD's thumbnail is 320x180 and
/// there is no larger one to ask for — the CLI hardcodes those dimensions in
/// its GraphQL query — so anything wider is an upscale that reads as blurry on
/// a Retina display. A clip's is full-size and would happily go bigger, but
/// two sizes for the same slot would be worse than one that is always crisp.
///
/// The frame is fixed and the image is fitted inside it, rather than the frame
/// following the image: a vertical clip is 9:16, and a card that changes shape
/// with the link would move every control below it.
struct VideoThumbnail: View {
  enum Source {
    /// We do not know the URL yet, because the metadata fetch is still out.
    case loading
    case url(URL?)
    case unavailable
  }

  let source: Source

  static let width: CGFloat = 160
  static let height: CGFloat = 90
  private static let corner: CGFloat = 6

  var body: some View {
    content
      .frame(width: Self.width, height: Self.height)
      .background(.quaternary)
      .clipShape(.rect(cornerRadius: Self.corner))
      // Twitch thumbnails are photographic and frequently near-black at the
      // edges, which would otherwise dissolve into a dark window.
      .overlay(RoundedRectangle(cornerRadius: Self.corner).strokeBorder(.separator))
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private var content: some View {
    switch source {
    case .loading:
      // No spinner. The card around this is redacted while it loads, and a
      // spinner inside a placeholder reads as a second, competing state.
      Color.clear

    case .url(let url):
      if let url {
        // `AsyncImage` reloads when the URL changes, which is exactly the
        // lifetime we want: one fetch per link, discarded with the window.
        // No cache, deliberately — nothing here is shown twice.
        AsyncImage(url: url) { phase in
          switch phase {
          case .success(let image):
            image.resizable().scaledToFit()
          case .failure:
            symbol("photo.badge.exclamationmark")
          case .empty:
            ProgressView().controlSize(.small)
          @unknown default:
            symbol("photo")
          }
        }
      } else {
        // Twitch has no preview for this one — a VOD still processing, or a
        // clip whose assets are gone. The slot stays, so nothing reflows.
        symbol("photo")
      }

    case .unavailable:
      symbol("photo.badge.exclamationmark")
    }
  }

  private func symbol(_ name: String) -> some View {
    Image(systemName: name)
      .font(.title2)
      .foregroundStyle(.tertiary)
  }
}

#Preview("Loading") {
  VideoCard(.loading)
    .padding()
    .frame(width: 480)
}

#Preview("Landscape VOD") {
  VideoCard(info: VideoInfo(
    streamer: "LeighXP",
    title: "indie horror + something else later?? ٩(◕‿◕)۶",
    createdAt: .now,
    duration: .seconds(991),
    qualities: [],
    thumbnailURL: URL(string: """
      https://static-cdn.jtvnw.net/cf_vods/d2nvs31859zcd8/\
      5652d9d62faa525b5c68_leighxp_317872278872_1786573193//thumb/thumb0-320x180.jpg
      """)))
  .padding()
  .frame(width: 480)
}

#Preview("No thumbnail") {
  VideoCard(info: VideoInfo(
    streamer: "LeighXP",
    title: "A VOD Twitch is still processing, so it has no preview frame yet",
    createdAt: .now,
    duration: .seconds(12_345),
    qualities: [],
    thumbnailURL: nil))
  .padding()
  .frame(width: 480)
}

#Preview("Metadata unavailable") {
  VideoCard(.unavailable(title: "LeighXP - 2026-08-12 - indie horror"))
    .padding()
    .frame(width: 480)
}
