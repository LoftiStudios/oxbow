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
      // spinner inside a placeholder reads as a second, competing state —
      // the bars say "nothing here yet" without claiming to be progress.
      //
      // `.unredacted()` because the bars ARE this slot's placeholder, and
      // `.redacted(.placeholder)` on the card would otherwise mask them to
      // the same flat grey block it gives the title and date. The earlier
      // drawn version was `Color` shapes, which redaction leaves alone; an
      // `Image` it does not, so this became load-bearing the moment the
      // pattern became an asset.
      TestPattern().unredacted()

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
/// The test card shown in the slot before there is anything to put in it.
///
/// **Why a picture rather than nothing.** The frame's *shape* was always
/// reserved, so nothing below it ever moved — but the slot went flat grey,
/// then a spinner, then snapped to a photograph, and three unrelated
/// appearances in a row read as a jump even though no geometry changed. Bars
/// are one appearance that belongs in a video window, and a frame fading up
/// over them reads as a picture tuning in rather than as a placeholder being
/// replaced.
///
/// **An asset, not seven rectangles.** The first version drew the bars in
/// SwiftUI, which scaled to any width with no `@2x` set — but it was an
/// approximation of the artwork rather than the artwork, and the pattern is
/// a design decision rather than a primitive. As an image, changing it is
/// replacing a file in the asset catalog and touching nothing here.
///
/// **Two files, one for each appearance**, chosen by the asset catalog from
/// the `luminosity` trait — so this draws no `colorScheme` of its own and
/// applies no opacity. An earlier drawn version was rendered at 55% to keep
/// full-strength bars from shouting in a dark window; artwork authored per
/// appearance has that judgement in it already, and trimming it here would
/// only undo the tuning.
///
/// Both are 1280x720, single-scale, so each is used at its natural pixel
/// size whatever the display: about 2.6x this card's ~490 physical pixels,
/// with headroom for a much wider window.
///
/// The artwork is the RCA Indian Head test card (1939), confirmed public
/// domain — recorded here because "is this ours to ship?" is the first
/// question anyone will have on seeing a recognisable broadcast mark in a
/// DMG, and the answer should not have to be re-researched.
private struct TestPattern: View {
  var body: some View {
    Image("TestPattern")
      .resizable()
      // `.fill`, not `.fit`: both assets are exactly 16:9, so this crops
      // nothing today — it is here so a replacement that is a pixel or two
      // off cannot letterbox itself and leave slivers of window showing
      // down the sides.
      .aspectRatio(contentMode: .fill)
      .allowsHitTesting(false)
  }
}

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
/// **A fade and nothing else.** An earlier version drifted each frame with a
/// slow Ken Burns scale, on the theory that a still which only cross-fades
/// reads as a slideshow while one that moves reads as footage. That is true
/// and it was still wrong here: this plays continuously beside a title
/// somebody is reading and a form they are filling in, and any motion that
/// is legible at a glance competes with both. Two rounds of toning it down
/// (halving the scale, then dropping the direction alternation) ended with
/// the honest answer being none of it.
///
/// **The outgoing frame is not faded out, only covered.** Cross-fading both
/// at once means each sits near half opacity at the midpoint, and whatever
/// is behind them shows through the gap — with the colour bars still
/// mounted, they visibly flashed between frames. Holding the previous frame
/// at full opacity and fading the next in over it keeps the picture opaque
/// end to end, which is also why the bars can be dropped entirely once the
/// frames arrive.
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
  /// Drives the fade of the loaded frames up over the colour-bar background.
  /// Separate from `loadedFrames` being non-nil, and set one step later on
  /// purpose: flipping both at once would insert the frames already at full
  /// opacity, and the fade would never be seen.
  @State private var framesVisible = false
  @State private var currentFrame = 0
  /// The frame sitting underneath at full opacity while `currentFrame` fades
  /// in over it. Equal to `currentFrame` except during a transition.
  @State private var previousFrame = 0
  /// How far `currentFrame` has faded in over `previousFrame`.
  @State private var fade: Double = 1
  /// How long the first frame takes to fade up over the colour bars. Longer
  /// than the crossing between frames: that one is a cut inside a running
  /// picture, this one is the picture arriving.
  private static let tuneInDuration: Double = 0.5
  private static let frameDwellSeconds: Double = 2.5
  private static let crossFadeDuration: Double = 0.6
  var body: some View {
    // A `ZStack` with the bars first, **not** `.background(TestPattern())`.
    // `background` takes its size from the primary view, and the primary
    // view here is empty until the frames finish loading — which collapsed
    // the whole slot to nothing for exactly as long as the bars were meant
    // to be filling it. In a `ZStack` the bars are a sibling that carries
    // the size themselves, so the frame is 16:9 from the first instant.
    ZStack {
      // Dropped the moment the frames are visible. It is only ever a
      // placeholder, and leaving it mounted underneath meant any gap in the
      // picture above — a mid-fade dip, a frame that failed to decode — let
      // colour bars flash through a loaded thumbnail.
      if !framesVisible {
        TestPattern()
      }

      Group {
        if let loadedFrames {
        if loadedFrames.count >= 2, !reduceMotion {
          ZStack {
            // The frame being left behind, held at full opacity. Never
            // faded out — see the doc comment: fading both at once leaves a
            // translucent midpoint that shows whatever is underneath.
            frameContent(loadedFrames[previousFrame])
            frameContent(loadedFrames[currentFrame])
              .opacity(fade)
          }
        } else {
          // Fewer than two frames, or Reduce Motion: frame 0, statically,
          // with no scale effect applied at all. `loadedFrames` is never
          // empty here — `VideoThumbnail` only builds this view for a
          // non-empty `originalURLs`, and `loadAllFrames` preserves count.
          frameContent(loadedFrames[0])
          }
        }
      }
      // The frames fade up *over* the bars rather than replacing them: there
      // is no instant where the slot is empty, and no swap to catch the eye.
      .opacity(framesVisible ? 1 : 0)
    }
    // Belt and suspenders with the rounded-rect `clipShape` already on
    // `VideoThumbnail.body`: that clip already contains anything drawn
    // inside this view's own bounds, but this makes the "must not bleed past
    // the corners" requirement true of this view on its own, not only in
    // combination with its parent.
    .clipped()
    .task(id: originalURLs) {
      // A new link's frames start hidden again, so the bars cover the old
      // video's picture while the new one loads rather than leaving it on
      // screen under a title that has already changed.
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

  /// Cycles `currentFrame` forever, dwelling on each and then fading the
  /// next in over it. Exits as soon as the surrounding `.task` is cancelled —
  /// checked both before starting a new dwell and immediately after every
  /// `Task.sleep`, since cancellation can land at either point.
  private func runLoop(frameCount: Int) async {
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(Self.frameDwellSeconds))
      guard !Task.isCancelled else { return }

      // Put the next frame above the current one at zero opacity, then fade
      // it up. `previousFrame` stays put and opaque for the whole crossing.
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
      // The crossing is over; collapse the two layers back onto one so the
      // next lap starts from a clean state.
      withTransaction(instant) { previousFrame = currentFrame }
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
