import SwiftUI
import OxbowKit
// NSImage: `FilmstripThumbnail` decodes fetched frame data itself, rather
// than through `AsyncImage`, so it can hold every frame in memory at once
// and fall back from a rewritten URL to Twitch's original one per frame.
import AppKit

/// The pasted link, made recognisable: the video's own preview image above
/// its title, who streamed it, and when.
///
/// **The card occupies its space before it has anything to put in it.** The
/// metadata fetch is a network round trip, so a card that only appeared once
/// it returned made the window jump by its own height at an unpredictable
/// moment. `.loading` draws the same layout at the same size with placeholder
/// text, and the real values replace it in place. This matters more now than
/// it did for the old horizontal card — the thumbnail is the tallest thing in
/// the card, not a fixed 90pt strip beside the text — so `VideoThumbnail`
/// reserves its height the same way in every state: as a 16:9 aspect ratio
/// against whatever width the card is given, never against its content.
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
    // Vertical, thumbnail on top: the mockup's answer to the old horizontal
    // card, where a fixed 160x90 well left most of a real thumbnail's detail
    // too small to read. Spanning the full content width costs the "never an
    // upscale" guarantee the old fixed frame made — a VOD's 320x180 source is
    // now frequently smaller than the frame it fills — but that trade is the
    // point of the redesign, not an oversight: a large, legible thumbnail
    // beats a small, crisp one here.
    VStack(alignment: .leading, spacing: 8) {
      VideoThumbnail(source: thumbnail)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.title3)
          .fontWeight(.bold)
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
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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

/// The preview image at a 16:9 frame spanning the card's full width, in every
/// state it can be in.
///
/// **The frame's shape is fixed; its size is not.** It used to be the other
/// way around — a hard 160x90, sized so a VOD's real 320x180 thumbnail (the
/// CLI hardcodes that size in its GraphQL query; there is no larger one to
/// ask for) was never upscaled. The redesign asks for a thumbnail that spans
/// the intake's own width instead, which gives up that guarantee for a
/// clip — its `thumbnailURL` is a single fixed asset, so a window wider than
/// its native size still upscales it. A VOD claws most of that back a
/// different way: `StreamThumbnail` rewrites its frame URLs to 1280x720
/// before this ever asks the CDN for them (see that type's doc comment for
/// the measurements behind the size), which covers the card's current
/// ~490 physical pixels on a 2x display with headroom for a wider window.
/// What the fixed *shape* still buys regardless of size is the reason the
/// frame existed at all — a vertical clip is 9:16, and a card that changed
/// shape with the link would move every control below it. `aspectRatio`
/// keeps that promise at any width.
struct VideoThumbnail: View {
  enum Source {
    /// We do not know the URLs yet, because the metadata fetch is still out.
    case loading
    /// The video's preview frames, exactly as Twitch gave them — never
    /// `StreamThumbnail`-rewritten here. Empty for a VOD Twitch has not
    /// generated previews for yet, one element for a clip, up to four for a
    /// VOD. `FilmstripThumbnail` is what decides how many of them to
    /// actually animate; this case just carries what there is.
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

    case .frames(let urls):
      if urls.isEmpty {
        // Twitch has no preview for this one — a VOD still processing, or a
        // clip whose assets are gone. The slot stays, so nothing reflows.
        thumbnailPlaceholderSymbol("photo")
      } else {
        FilmstripThumbnail(originalURLs: urls)
      }

    case .unavailable:
      thumbnailPlaceholderSymbol("photo.badge.exclamationmark")
    }
  }
}

/// Shared between `VideoThumbnail` and `FilmstripThumbnail`: the same muted
/// SF Symbol treatment for every "there is no image here" case, so a missing
/// thumbnail and a failed frame within the filmstrip read as the same kind
/// of absence rather than two different ones.
private func thumbnailPlaceholderSymbol(_ name: String) -> some View {
  Image(systemName: name)
    .font(.title2)
    .foregroundStyle(.tertiary)
}

/// Plays a VOD's sampled preview frames as a slow, continuous filmstrip: a
/// cross-fade between frames with a gentle Ken Burns drift on each, so the
/// card reads as footage of the stream rather than one upscaled still.
///
/// **Why frames at all, and why this many.** Twitch samples four frames
/// across a VOD — measured against the live CDN on VOD 2859050150: four
/// genuinely different JPEGs (distinct SHAs, 12-14 KB each at Twitch's
/// default 320x180), not one repeated. A clip carries exactly one, already
/// full size. This view is built to behave correctly at whatever count it is
/// actually handed: 2 or more animates, exactly 1 plays it straight — the
/// zero-frame case never reaches here at all, since `VideoThumbnail` keeps
/// its placeholder treatment for that.
///
/// **Why a drift, not just a fade.** A still that only cross-fades reads as
/// a slideshow. A still that also scales and pans very slightly reads as
/// footage, which is the entire point of showing a VOD's own sampled frames
/// instead of a single static thumbnail. Linear easing within a frame's
/// dwell, because an ease-in-out here reads as the image breathing rather
/// than drifting.
///
/// **One anchor for every frame, not an alternating one.** The first version
/// flipped `scaleEffect`'s `anchor` between `.leading` and `.trailing` frame
/// to frame, on the theory that always zooming toward the same edge would
/// give a four-frame loop a visible bias to one side. It does — and that
/// bias is cheaper than the alternative, because flipping the direction at
/// every cut is a second source of movement on top of the cut and the drift,
/// and the eye catches a reversal far more readily than a constant slow
/// travel. A consistent `.leading` reads as one unhurried push in one
/// direction; the alternating version read as fidgeting.
///
/// **Why `.task`, not a `Timer`.** The loop has to stop the moment this view
/// leaves the hierarchy — a closed intake window must not leave a repeating
/// timer alive behind it. Driving the cycle from `.task(id:)` gets that for
/// free: structured concurrency cancels the task (and, mid-`Task.sleep`,
/// unwinds it immediately) when the view disappears, with nothing here having
/// to remember to invalidate anything.
struct FilmstripThumbnail: View {
  /// Every frame's URL exactly as Twitch gave it — never
  /// `StreamThumbnail`-rewritten. Kept as the fallback: the CDN size rewrite
  /// is undocumented behaviour, not a contract (see `StreamThumbnail`'s doc
  /// comment), so a frame whose rewritten URL fails to load has to retry at
  /// the size Twitch actually promised before that slot gives up and shows
  /// the placeholder.
  let originalURLs: [URL]

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// `nil` until every frame has been attempted at least once; then one
  /// entry per frame, with `nil` inside meaning both its rewritten and
  /// original URL failed to load. Loading every frame before setting this is
  /// what "hold on frame 0 until all are in" means in practice — cycling to
  /// a frame that has not arrived yet would flash the placeholder mid-loop,
  /// which reads as a glitch rather than as loading.
  @State private var loadedFrames: [Image?]?
  @State private var currentFrame = 0
  /// One entry per frame: how far into its own Ken Burns drift it has
  /// animated, from 1 (no scale) toward `maxScale`. Indexed rather than a
  /// single shared value so the frame fading out during a cross-fade keeps
  /// the scale it had reached, instead of snapping back to 1 the instant the
  /// next frame's dwell begins resetting *its* entry.
  @State private var frameScales: [CGFloat] = []

  private static let frameDwellSeconds: Double = 2.5
  private static let crossFadeDuration: Double = 0.6
  /// How far a frame drifts over its dwell.
  ///
  /// **Deliberately smaller than it wants to be.** The drift exists to stop
  /// four stills reading as a slideshow, and it has done its job the moment
  /// the card feels like footage — anything past that is an animation
  /// competing for attention with the title beside it and the form below it,
  /// in a window whose whole purpose is a decision about a download.
  ///
  /// Started at 1.05, which was legible as movement at a glance rather than
  /// only on inspection. At 1.025 over a 2.5s dwell the frame still settles
  /// somewhere visibly different by the end, and nothing about any single
  /// instant of it reads as motion.
  private static let maxScale: CGFloat = 1.025

  var body: some View {
    Group {
      if let loadedFrames {
        if loadedFrames.count >= 2, !reduceMotion {
          ZStack {
            ForEach(loadedFrames.indices, id: \.self) { index in
              frameContent(loadedFrames[index])
                .scaleEffect(
                  index < frameScales.count ? frameScales[index] : 1,
                  anchor: .leading)
                .opacity(index == currentFrame ? 1 : 0)
            }
          }
          // Ties the cross-fade to `currentFrame` alone, not to
          // `frameScales` — the drift below is animated explicitly with its
          // own linear curve, and letting this catch it too would round its
          // continuous ramp down to the fade's easeInOut.
          .animation(.easeInOut(duration: Self.crossFadeDuration), value: currentFrame)
        } else {
          // Fewer than two frames, or Reduce Motion: frame 0, statically,
          // with no scale effect applied at all. `loadedFrames` is never
          // empty here — `VideoThumbnail` only builds this view for a
          // non-empty `originalURLs`, and `loadAllFrames` preserves count.
          frameContent(loadedFrames[0])
        }
      } else {
        ProgressView().controlSize(.small)
      }
    }
    // Belt and suspenders with the rounded-rect `clipShape` already on
    // `VideoThumbnail.body`: that clip already contains anything drawn
    // inside this view's own bounds, but this makes the "must not bleed past
    // the corners" requirement true of this view on its own, not only in
    // combination with its parent.
    .clipped()
    .task(id: originalURLs) {
      let loaded = await Self.loadAllFrames(originalURLs)
      guard !Task.isCancelled else { return }
      frameScales = Array(repeating: 1, count: loaded.count)
      currentFrame = 0
      loadedFrames = loaded
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

  /// Cycles `currentFrame` forever, dwelling on each with a linear scale
  /// ramp before cross-fading to the next. Exits as soon as the surrounding
  /// `.task` is cancelled — checked both before starting a new dwell and
  /// immediately after every `Task.sleep`, since cancellation can land at
  /// either point.
  private func runLoop(frameCount: Int) async {
    while !Task.isCancelled {
      withAnimation(.linear(duration: Self.frameDwellSeconds)) {
        frameScales[currentFrame] = Self.maxScale
      }
      try? await Task.sleep(for: .seconds(Self.frameDwellSeconds))
      guard !Task.isCancelled else { return }

      let next = (currentFrame + 1) % frameCount
      // Snap the *upcoming* frame's scale back to 1 before it becomes
      // visible, disabling animation for just this write — otherwise it
      // would visibly ease down from wherever its last lap left it, right as
      // it fades in.
      var reset = Transaction()
      reset.disablesAnimations = true
      withTransaction(reset) {
        frameScales[next] = 1
      }
      currentFrame = next
    }
  }

  /// Attempts every frame in order and waits for all of them — see the
  /// `loadedFrames` doc comment for why this has to finish before anything
  /// cycles. Sequential rather than concurrent: four small JPEGs is not
  /// enough work to be worth the `Sendable`/actor bookkeeping a task group
  /// would add here, and every frame still has to arrive before playback
  /// starts either way.
  private static func loadAllFrames(_ originalURLs: [URL]) async -> [Image?] {
    var results: [Image?] = []
    results.reserveCapacity(originalURLs.count)
    for original in originalURLs {
      results.append(await loadFrame(original: original))
    }
    return results
  }

  /// Tries `StreamThumbnail`'s rewritten URL first, then falls back to the
  /// URL Twitch actually gave us for this frame — the rewrite is undocumented
  /// CDN behaviour, not a contract, so it has to be allowed to simply not
  /// work. Skips straight to the original when the rewrite is a no-op (a
  /// clip's already-full-size URL, or anything else `StreamThumbnail` left
  /// alone) rather than fetching the same URL twice.
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
  /// The real VOD behind
  /// `Tests/OxbowKitTests/Fixtures/cli-output/info-vod-raw.stdout`, with
  /// `frameCount` of its four real sampled frames — so a preview can show
  /// either the full filmstrip or the partial-metadata case where Twitch has
  /// only produced the first one so far, from one shared streamer/title/
  /// duration rather than two copies of them drifting apart.
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

/// A real four-frame VOD, URLs taken from the fixture behind
/// `Tests/OxbowKitTests/Fixtures/cli-output/info-vod-raw.stdout` — this is
/// the shape `FilmstripThumbnail` exists for: `StreamThumbnail` rewrites each
/// to 1280x720 before fetch, then all four cross-fade and drift.
#Preview("Landscape VOD - filmstrip") {
  VideoCard(info: .previewVOD(frameCount: 4))
    .padding()
    .frame(width: 480)
}

/// Same VOD, but Twitch has only sampled one frame so far — plausible for a
/// broadcast that finished recording moments ago. `FilmstripThumbnail` must
/// draw this frame statically rather than trying to cross-fade it with
/// itself.
#Preview("Landscape VOD - single frame") {
  VideoCard(info: .previewVOD(frameCount: 1))
    .padding()
    .frame(width: 480)
}

/// A clip: one already-full-size frame, shaped so `StreamThumbnail` leaves it
/// alone (see that type's doc comment for why the shapes have to differ).
/// Exercises the same "fewer than two frames plays statically" path as the
/// single-frame VOD above, from the other kind of video that reaches it.
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

// No "Reduce Motion" preview: macOS 26's SDK made
// `EnvironmentValues.accessibilityReduceMotion` get-only (confirmed against
// SwiftUICore.swiftinterface — it now reads `get` with no `set`, where a
// private `_accessibilityReduceMotion` still has both), so a `#Preview`
// cannot force it on through public API the way it used to. Reading it via
// `@Environment` in `FilmstripThumbnail` still works fine at runtime; only
// *overriding* it for a canvas preview is closed off. The "Landscape VOD -
// single frame" preview above exercises the same code path Reduce Motion
// takes (`loadedFrames.count >= 2` false), which is the only verification
// available without a real system with Reduce Motion enabled.

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
