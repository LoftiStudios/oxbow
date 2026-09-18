import SwiftUI
import OxbowKit
import AppKit

/// Video preview and metadata, with a fixed 16:9 slot and matching placeholders to prevent
/// layout shifts during loading.
struct VideoCard: View {
  enum Content {
    /// Metadata is on its way. Same layout, redacted.
    case loading
    case loaded(VideoInfo)
    /// Preserve the card's layout and any known title when metadata is unavailable.
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
      // Use realistic placeholder lengths to minimize visual movement on load.
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
        thumbnail: .frames(info.thumbnailURLs))

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
    VStack(alignment: .leading, spacing: 8) {
      VideoThumbnail(source: thumbnail)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.title3)
          .fontWeight(.bold)
          .lineLimit(2)
          // Allow long titles to wrap.
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
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private func details(of info: VideoInfo) -> String {
    let date = info.createdAt.formatted(date: .abbreviated, time: .omitted)
    return "\(date) · \(Self.length(of: info.duration))"
  }

  private static func length(of duration: Duration) -> String {
    VideoLength.timecode(duration)
  }
}

/// Keep a full-width 16:9 slot in every state, including portrait clips. StreamThumbnail
/// requests larger VOD frames; fixed clip assets may upscale.
struct VideoThumbnail: View {
  enum Source {
    case loading
    /// Original Twitch URLs: zero for unavailable previews, one for clips, up to four for VODs.
    /// FilmstripThumbnail handles rewriting and animation.
    case frames([URL])
    case unavailable
  }

  let source: Source

  private static let aspectRatio: CGFloat = 16.0 / 9.0
  private static let corner: CGFloat = 8

  var body: some View {
    content
      .aspectRatio(Self.aspectRatio, contentMode: .fit)
      .frame(maxWidth: .infinity)
      .background(.quaternary)
      .clipShape(.rect(cornerRadius: Self.corner))
      // Keep dark image edges distinct from the window background.
      .overlay(RoundedRectangle(cornerRadius: Self.corner).strokeBorder(.separator))
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private var content: some View {
    switch source {
    case .loading:
      // The test pattern is already a placeholder; unredacted prevents the card's redaction
      // from masking it.
      TestPattern().unredacted()

    case .frames(let urls):
      if urls.isEmpty {
        thumbnailPlaceholderSymbol("photo")
      } else {
        FilmstripThumbnail(originalURLs: urls)
      }

    case .unavailable:
      thumbnailPlaceholderSymbol("photo.badge.exclamationmark")
    }
  }
}

/// Loading artwork: the public-domain RCA Indian Head test card (1939). The asset catalog
/// selects light/dark 1280x720 versions; apply no additional appearance tint or opacity.
private struct TestPattern: View {
  var body: some View {
    Image("TestPattern")
      .resizable()
      // Fill the slot even if replacement artwork differs slightly from 16:9.
      .aspectRatio(contentMode: .fill)
      .allowsHitTesting(false)
  }
}

private func thumbnailPlaceholderSymbol(_ name: String) -> some View {
  Image(systemName: name)
    .font(.title2)
    .foregroundStyle(.tertiary)
    // Expand the placeholder to preserve the outer 16:9 frame instead of inheriting an image's
    // small ideal size.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

/// Cycle multiple sampled frames with fades; show a single frame statically. Keep the outgoing
/// frame opaque beneath the incoming one to prevent background flashes. A task-bound loop stops
/// when the view disappears.
struct FilmstripThumbnail: View {
  /// Keep original URLs as fallbacks because CDN size rewriting is undocumented.
  let originalURLs: [URL]

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Nil until all frames have been attempted; inner nil means both rewritten and original URLs
  /// failed. Do not cycle through frames still loading.
  @State private var loadedFrames: [Image?]?
  /// Set after loadedFrames so the inserted frames can fade in from zero opacity.
  @State private var framesVisible = false
  @State private var currentFrame = 0
  /// The frame sitting underneath at full opacity while `currentFrame` fades
  /// in over it. Equal to `currentFrame` except during a transition.
  @State private var previousFrame = 0
  /// How far `currentFrame` has faded in over `previousFrame`.
  @State private var fade: Double = 1
  /// Initial fade from the loading artwork, separate from frame-to-frame timing.
  private static let tuneInDuration: Double = 0.5
  private static let frameDwellSeconds: Double = 2.5
  private static let crossFadeDuration: Double = 0.6
  var body: some View {
    // A sibling test pattern gives the ZStack its size before frames load; background alone
    // would inherit empty content size.
    ZStack {
      // Remove loading artwork once frames are visible so failed frames cannot expose it.
      if !framesVisible {
        TestPattern()
      }

      Group {
        if let loadedFrames {
        if loadedFrames.count >= 2, !reduceMotion {
          ZStack {
            frameContent(loadedFrames[previousFrame])
            frameContent(loadedFrames[currentFrame])
              .opacity(fade)
          }
        } else {
          // Show frame zero without animation for a single frame or Reduce Motion.
          // loadAllFrames preserves the non-empty input count.
          frameContent(loadedFrames[0])
          }
        }
      }
      .opacity(framesVisible ? 1 : 0)
    }
    .clipped()
    .task(id: originalURLs) {
      // Hide the previous video's frames as soon as the link changes.
      framesVisible = false
      let loaded = await Self.loadAllFrames(originalURLs)
      guard !Task.isCancelled else { return }
      currentFrame = 0
      previousFrame = 0
      fade = 1
      loadedFrames = loaded
      withAnimation(.easeInOut(duration: Self.tuneInDuration)) {
        framesVisible = true
      }
      guard loaded.count >= 2, !reduceMotion else { return }
      await runLoop(frameCount: loaded.count)
    }
  }

  @ViewBuilder
  private func frameContent(_ image: Image?) -> some View {
    if let image {
      image.resizable().scaledToFit()
    } else {
      thumbnailPlaceholderSymbol("photo.badge.exclamationmark")
    }
  }

  /// Cycle frames until the surrounding task is cancelled, checking cancellation around each
  /// sleep.
  private func runLoop(frameCount: Int) async {
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(Self.frameDwellSeconds))
      guard !Task.isCancelled else { return }

      // Fade the next frame over the opaque current frame.
      previousFrame = currentFrame
      var instant = Transaction()
      instant.disablesAnimations = true
      withTransaction(instant) {
        currentFrame = (currentFrame + 1) % frameCount
        fade = 0
      }
      withAnimation(.easeInOut(duration: Self.crossFadeDuration)) { fade = 1 }

      try? await Task.sleep(for: .seconds(Self.crossFadeDuration))
      guard !Task.isCancelled else { return }
      withTransaction(instant) { previousFrame = currentFrame }
    }
  }

  /// Attempt every frame before playback; preserve input order and count, including failures.
  private static func loadAllFrames(_ originalURLs: [URL]) async -> [Image?] {
    var results: [Image?] = []
    results.reserveCapacity(originalURLs.count)
    for original in originalURLs {
      results.append(await loadFrame(original: original))
    }
    return results
  }

  /// Try the rewritten URL, then the original. Skip duplicate requests when rewriting leaves
  /// the URL unchanged.
  private static func loadFrame(original: URL) async -> Image? {
    let rewritten = StreamThumbnail.rewritten(original)
    if rewritten != original, let image = await loadImage(from: rewritten) {
      return image
    }
    return await loadImage(from: original)
  }

  private static func loadImage(from url: URL) async -> Image? {
    guard let (data, response) = try? await URLSession.shared.data(from: url),
          (response as? HTTPURLResponse)?.statusCode == 200,
          let nsImage = NSImage(data: data)
    else { return nil }
    return Image(nsImage: nsImage)
  }
}

extension VideoInfo {
  /// Select sampled frames from the info-vod-raw.stdout fixture for consistent previews.
  fileprivate static func previewVOD(frameCount: Int) -> VideoInfo {
    let base = """
      https://static-cdn.jtvnw.net/cf_vods/d2nvs31859zcd8/\
      5652d9d62faa525b5c68_leighxp_317872278872_1786573193//thumb/thumb
      """
    return VideoInfo(
      streamer: "LeighXP",
      title: "indie horror + something else later?? ٩(◕‿◕)۶",
      createdAt: .now,
      duration: .seconds(991),
      qualities: [],
      thumbnailURLs: (0..<frameCount).map { URL(string: "\(base)\($0)-320x180.jpg")! })
  }
}

#Preview("Loading") {
  VideoCard(.loading)
    .padding()
    .frame(width: 480)
}

#Preview("Landscape VOD - filmstrip") {
  VideoCard(info: .previewVOD(frameCount: 4))
    .padding()
    .frame(width: 480)
}

/// One sampled frame must display statically.
#Preview("Landscape VOD - single frame") {
  VideoCard(info: .previewVOD(frameCount: 1))
    .padding()
    .frame(width: 480)
}

/// A clip's original URL must remain unchanged and display statically.
#Preview("Clip") {
  VideoCard(info: VideoInfo(
    streamer: "xQc",
    title: "Me on stream",
    createdAt: .now,
    duration: .seconds(7),
    qualities: [],
    thumbnailURLs: [URL(string: """
      https://static-cdn.jtvnw.net/twitch-video-assets/\
      twitch-vap-video-assets-prod-us-west-2/c0a947c9-4ed3-4fb0-a7c8-b43160ee371c/\
      landscape/thumb/thumb-0000000000-1920x1080.jpg
      """)!]))
  .padding()
  .frame(width: 480)
}

// macOS 26 makes accessibilityReduceMotion read-only in previews. The single-frame preview
// exercises the static branch; verify Reduce Motion with the system setting.

#Preview("No thumbnail") {
  VideoCard(info: VideoInfo(
    streamer: "LeighXP",
    title: "A VOD Twitch is still processing, so it has no preview frame yet",
    createdAt: .now,
    duration: .seconds(12_345),
    qualities: [],
    thumbnailURLs: []))
  .padding()
  .frame(width: 480)
}

#Preview("Metadata unavailable") {
  VideoCard(.unavailable(title: "LeighXP - 2026-08-12 - indie horror"))
    .padding()
    .frame(width: 480)
}
