import SwiftUI

/// The trim range as a ruler you can drag, over the VOD's whole duration.
///
/// Binds to the same two `String`s the trim fields do rather than to a pair of
/// `Duration`s of its own. `IntakeModel` keeps trim times as text on purpose —
/// a half-typed value has to be a visible error, not silently no trim at all —
/// and a second source of truth here would have to be reconciled with that one
/// on every keystroke. So the handles' positions are derived from the text on
/// every frame, and a drag writes text back.
///
/// That round-trip is only lossless because it is sub-pixel: `time(atX:)`
/// snaps to the drag unit, and one unit is ~1pt on a 40-minute VOD and ~1.4pt
/// on a six-hour one. The handle does snap, by about a pixel.
struct TrimTimeline: View {
  let duration: Duration
  @Binding var startText: String
  @Binding var endText: String
  var isDimmed = false

  @State private var trackWidth: CGFloat = 0
  @GestureState private var dragOrigin: CGFloat?

  private enum Handle { case start, end }

  private enum Metrics {
    static let trackHeight: CGFloat = 56
    static let corner: CGFloat = 8
    /// The scale is inset by the handle's radius at both ends. Without it the
    /// handle at 00:00:00 is half-clipped by the corner radius — and 00:00:00
    /// is where the start handle sits by default, so it is the first thing
    /// anyone sees.
    static let inset: CGFloat = 5
    static let hit: CGFloat = 15
    static let line: CGFloat = 1.5
    static let dot: CGFloat = 7
    static let labelRow: CGFloat = 18
    static let tickLabel: CGFloat = 14
    static let tickMajor: CGFloat = 10
    static let tickMinor: CGFloat = 6
    /// How far the selection sits inside the track, top and bottom, so the
    /// gradient still shows above and below it — without this the selection
    /// reads as a second track laid over the first rather than as a region cut
    /// into one.
    static let selectionInset: CGFloat = 6
    static let selectionCorner: CGFloat = 4
    /// The lollipops run from just above the timestamps down to exactly the
    /// selection's own bottom edge — derived from `selectionInset` rather than
    /// written out, so the two cannot drift apart when either is tuned. They
    /// are allowed to overlap the timestamps: they mark where the range ends,
    /// which is worth more than an unbroken label.
    static let handleTop: CGFloat = 12
    static var handleBottom: CGFloat { trackHeight - selectionInset }
  }

  private var scale: TimelineScale {
    TimelineScale(duration: duration, width: max(0, trackWidth - 2 * Metrics.inset))
  }
  private var startTime: Duration { Timecode.parse(startText) ?? .zero }
  private var endTime: Duration { Timecode.parse(endText) ?? duration }
  private func viewX(_ time: Duration) -> CGFloat { scale.x(for: time) + Metrics.inset }

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: Metrics.corner)
        .fill(Self.track)
        // A lit top lip and a shaded bottom one. One hairline in each
        // direction is what gives a flat fill thickness — without it the
        // gradient reads as a painted rectangle rather than a strip with an
        // edge you could catch a fingernail on.
        .overlay(
          RoundedRectangle(cornerRadius: Metrics.corner)
            .strokeBorder(
              LinearGradient(
                colors: [.white.opacity(0.5), .black.opacity(0.28)],
                startPoint: .top,
                endPoint: .bottom),
              lineWidth: 1))
        // Sits fractionally proud of the form, so the channel cut into it has
        // something to be cut into.
        .shadow(color: .black.opacity(0.22), radius: 1.5, x: 0, y: 1)
      selection
      ruler
      handle(.start)
      handle(.end)
    }
    .frame(height: Metrics.trackHeight)
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trackWidth = $0 }
    .opacity(isDimmed ? 0.4 : 1)
    // `.disabled` rather than `.allowsHitTesting`: the latter stops the mouse
    // but leaves the handles tab-focusable and adjustable by VoiceOver, so a
    // nudge would overwrite the half-typed value the dimming exists to keep
    // visible.
    .disabled(isDimmed)
  }

  /// The track's own surface: a vertical wash from `#B6B5C5` down to
  /// `#787697`.
  ///
  /// Fixed colours rather than a material, because the ruler is a physical
  /// object — the point of the gradient is that light falls across a strip of
  /// metal — and a material would take its cast from whatever sits behind the
  /// form instead. It is dark enough at the bottom to carry the light handle
  /// dot and light enough at the top for the timestamps to read black.
  private static let track = LinearGradient(
    colors: [
      Color(red: 0xB6 / 255, green: 0xB5 / 255, blue: 0xC5 / 255),
      Color(red: 0x78 / 255, green: 0x76 / 255, blue: 0x97 / 255),
    ],
    startPoint: .top,
    endPoint: .bottom)

  /// Everything drawn on the track: ticks, timestamps, handles.
  ///
  /// A fixed colour, not `.primary`. The track above is the same lavender in
  /// either appearance, so its markings have to be too — `.primary` inverts to
  /// white in dark mode and the timestamps all but vanished against the pale
  /// top of the gradient.
  private static let ink = Color(red: 0x1C / 255, green: 0x1B / 255, blue: 0x2A / 255)

  /// The chosen range, as a pane of glass lying on the track.
  ///
  /// **Lighter than the strip, not darker.** Liquid Glass is a light-adding
  /// material; every attempt to make it a dark recess fought that and came out
  /// as grey mud. Lifting the selection instead lets it behave the way it was
  /// built to, and matches how selection reads everywhere else in the system —
  /// the chosen thing is the lit one.
  ///
  /// `.clear` rather than `.regular`: the ruler underneath has to stay legible,
  /// and the heavier material desaturates the strip's violet toward grey. What
  /// the glass buys over a hand-rolled wash is the specular lip along its
  /// bottom edge, which is a real edge highlight rather than an approximation
  /// of one.
  private var selection: some View {
    let start = viewX(startTime), end = viewX(endTime)
    return Color.clear
      .glassEffect(.clear, in: .rect(cornerRadius: Metrics.selectionCorner))
      .frame(width: max(0, end - start))
      // The top inset clears the timestamps rather than matching the bottom.
      // Multiplied through, the channel darkens the strip enough that the dark
      // ink of a label sitting on it loses most of its contrast — so the
      // timestamps stay out on the light band and the channel begins where the
      // ticks do.
      .padding(.top, Metrics.labelRow)
      .padding(.bottom, Metrics.selectionInset)
      .offset(x: start)
      .frame(maxWidth: .infinity, alignment: .leading)
      // Still clipped to the track: inset vertically it can no longer overrun
      // the top and bottom corners, but at either extreme it still meets the
      // track's own rounded ends.
      .clipShape(.rect(cornerRadius: Metrics.corner))
  }

  /// Drawn over the selection fill, not under it, so the ruler reads
  /// continuously across the whole track. One `Canvas` rather than 73 shape
  /// views: three stroke weights in a single pass, and no view identity to
  /// churn on every frame of a drag.
  private var ruler: some View {
    VStack(alignment: .leading, spacing: 0) {
      labelRow
      Canvas { context, _ in
        for tick in scale.ticks {
          var path = Path()
          path.move(to: CGPoint(x: tick.x + Metrics.inset, y: 0))
          path.addLine(to: CGPoint(x: tick.x + Metrics.inset, y: Self.length(of: tick.height)))
          context.stroke(
            path, with: .color(Self.ink.opacity(Self.opacity(of: tick.height))), lineWidth: 1)
        }
      }
      .frame(height: Metrics.tickLabel)
      Spacer(minLength: 0)
    }
    // A picture of a scale. The two text fields carry the actual values.
    .accessibilityHidden(true)
  }

  private static func length(of height: TimelineScale.TickHeight) -> CGFloat {
    switch height {
    case .label: Metrics.tickLabel
    case .major: Metrics.tickMajor
    case .minor: Metrics.tickMinor
    }
  }

  private static func opacity(of height: TimelineScale.TickHeight) -> Double {
    switch height {
    case .label: 0.85
    case .major: 0.65
    case .minor: 0.40
    }
  }

  /// Every label gets the same fixed frame, because Monaco is fixed-width and
  /// `Timecode.format` always produces eight characters — so a label's left
  /// edge is arithmetic rather than a measurement.
  private var labelRow: some View {
    ZStack(alignment: .topLeading) {
      ForEach(scale.labels, id: \.x) { label in
        Text(label.text)
          .font(.custom("Monaco", size: 11))
          .frame(width: TimelineScale.labelWidth, alignment: .leading)
          .offset(x: leftEdge(of: label))
      }
    }
    .frame(height: Metrics.labelRow, alignment: .topLeading)
    .foregroundStyle(Self.ink)
  }

  private func leftEdge(of label: TimelineScale.Label) -> CGFloat {
    switch label.anchor {
    case .leading: Metrics.inset
    case .center: Metrics.inset + label.x - TimelineScale.labelWidth / 2
    case .trailing: Metrics.inset + scale.width - TimelineScale.labelWidth
    }
  }

  private func handle(_ edge: Handle) -> some View {
    let time = edge == .start ? startTime : endTime
    return ZStack {
      Capsule()
        .fill(Self.ink)
        .frame(width: Metrics.line, height: Metrics.handleBottom - Metrics.handleTop)
        .offset(
          y: (Metrics.handleTop + Metrics.handleBottom) / 2 - Metrics.trackHeight / 2)
      Circle().fill(Self.ink).frame(width: Metrics.dot, height: Metrics.dot)
        .offset(y: Metrics.handleTop + Metrics.dot / 2 - Metrics.trackHeight / 2)
    }
    // Both children are positioned by an offset from this box's centre, so it
    // has to be the full track height — sizing it to the tallest child would
    // silently move them.
    .frame(width: Metrics.hit, height: Metrics.trackHeight)
    .contentShape(Rectangle())
    .offset(x: viewX(time) - Metrics.hit / 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .gesture(
      DragGesture(minimumDistance: 0)
        // `@GestureState` rather than `@State`: it resets itself when the
        // gesture ends *or* is cancelled, and a stale origin surviving a
        // cancelled drag would teleport the handle on the next grab.
        .updating($dragOrigin) { _, origin, _ in
          if origin == nil { origin = viewX(time) }
        }
        .onChanged { value in
          // Captured once per gesture and never recomputed from the current
          // value: `time(atX:)` snaps and `x(for:)` does not, so deriving the
          // origin every frame feeds that rounding back through the
          // projection and the handle drifts behind the cursor and sticks.
          guard let origin = dragOrigin else { return }
          move(edge, to: scale.time(atX: origin + value.translation.width - Metrics.inset))
        })
    // `.pointerStyle` rather than NSCursor: no push/pop pairs to keep balanced
    // across a view that redraws on every frame of a drag.
    .pointerStyle(.frameResize(position: edge == .start ? .leading : .trailing))
    // Deliberately not `.focusable()`. Both handles are positioned by
    // `.offset`, which moves what is drawn but not the layout frame, so both
    // report the same full-width frame and the focus engine has no geometry to
    // order them by — tab jumped between them arbitrarily. Giving them real
    // layout would fix the order but not the premise: a `Slider` is one tab
    // stop on this platform, never two, and the Start and End fields beside
    // the timeline already carry these same two values in reading order. The
    // handles stay a pointer affordance; VoiceOver still reaches them through
    // the adjustable action below.
    .accessibilityLabel(edge == .start ? "Trim start" : "Trim end")
    .accessibilityValue(Timecode.format(time))
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: nudge(edge, bySteps: 1)
      case .decrement: nudge(edge, bySteps: -1)
      @unknown default: break
      }
    }
  }

  /// Clamped so the handles keep at least `minimumSeparation` between them,
  /// which is what makes it impossible for a drag to be the thing that trips
  /// `IntakeModel.trimIsInvalid`.
  ///
  /// **An extreme clears the field rather than writing the boundary value.**
  /// Empty already means "no trim" to the model, so clearing keeps
  /// `effectiveDuration` computing from the true `info.duration` instead of a
  /// snapped copy of it, and brings the `End of video` placeholder back.
  private func move(_ edge: Handle, to time: Duration) {
    switch edge {
    case .start:
      let clamped = min(time, endTime - minimumSeparation)
      startText = clamped <= .zero ? "" : Timecode.format(clamped)
    case .end:
      let clamped = max(time, startTime + minimumSeparation)
      endText = clamped >= duration ? "" : Timecode.format(clamped)
    }
  }

  /// One drag unit, or the time occupied by a handle's hit target — whichever
  /// is longer. A unit is about a point on a long video, so a unit-wide
  /// selection would leave the two hit targets on top of each other and the
  /// handle underneath could never be picked up again.
  private var minimumSeparation: Duration {
    max(scale.dragUnit, scale.time(atX: Metrics.hit))
  }

  private func nudge(_ edge: Handle, bySteps steps: Int) {
    let current = edge == .start ? startTime : endTime
    move(edge, to: current + .seconds(scale.dragUnitSeconds * steps))
  }
}

// MARK: - Previews

private struct TimelinePreview: View {
  let duration: Duration
  @State var start: String
  @State var end: String
  var isDimmed = false
  var width: CGFloat = 500

  var body: some View {
    TrimTimeline(duration: duration, startText: $start, endText: $end, isDimmed: isDimmed)
      .frame(width: width)
      .padding()
  }
}

#Preview("40:00 - whole video") {
  TimelinePreview(duration: .seconds(2400), start: "", end: "")
}

/// The first ten minutes cut off the front — the common case, and the one that
/// shows the selection fill against the untrimmed remainder.
#Preview("40:00 - first ten minutes trimmed") {
  TimelinePreview(duration: .seconds(2400), start: "00:10:00", end: "")
}

/// The test fixture's VOD. Short enough that the drag unit is 2s and the
/// labels are not round minutes — the case the ruler has to degrade into.
#Preview("16:31") {
  TimelinePreview(duration: .seconds(991), start: "", end: "")
}

/// Long enough for a 30s drag unit, and the duration whose last label would
/// read 03:17:45 if the endpoints were snapped.
#Preview("3:17:43") {
  TimelinePreview(duration: .seconds(11863), start: "00:45:00", end: "03:00:00")
}

/// Narrow enough to drop from five labels to three.
#Preview("Narrow - three labels") {
  TimelinePreview(duration: .seconds(2400), start: "", end: "", width: 300)
}

/// What a half-typed trim time looks like: inert and dimmed, with the reason
/// shown by the form's own error row rather than here.
#Preview("Dimmed - invalid text") {
  TimelinePreview(duration: .seconds(2400), start: "half an hour", end: "", isDimmed: true)
}
