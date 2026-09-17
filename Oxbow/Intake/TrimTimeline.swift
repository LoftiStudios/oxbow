import SwiftUI

/// Drag handles read and write the same text bindings as the trim fields. TimelineScale snaps
/// drag output; incomplete typed values remain visible for validation.
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
    /// Inset the scale by the handle radius to avoid clipping at endpoints.
    static let inset: CGFloat = 5
    static let hit: CGFloat = 15
    static let line: CGFloat = 1.5
    static let dot: CGFloat = 7
    static let labelRow: CGFloat = 18
    static let tickLabel: CGFloat = 14
    static let tickMajor: CGFloat = 10
    static let tickMinor: CGFloat = 6
    /// Inset the selection vertically to leave the track visible around it.
    static let selectionInset: CGFloat = 6
    static let selectionCorner: CGFloat = 4
    /// Derive handle bottoms from selectionInset to keep them aligned with the selected range.
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
        .overlay(
          RoundedRectangle(cornerRadius: Metrics.corner)
            .strokeBorder(
              LinearGradient(
                colors: [.white.opacity(0.5), .black.opacity(0.28)],
                startPoint: .top,
                endPoint: .bottom),
              lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 1.5, x: 0, y: 1)
      selection
      ruler
      handle(.start)
      handle(.end)
    }
    .frame(height: Metrics.trackHeight)
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trackWidth = $0 }
    .opacity(isDimmed ? 0.4 : 1)
    // Disable accessibility adjustment too, so it cannot overwrite invalid typed input.
    .disabled(isDimmed)
  }

  /// Fixed gradient supports dark timestamps at the top and light handle dots below.
  private static let track = LinearGradient(
    colors: [
      Color(red: 0xB6 / 255, green: 0xB5 / 255, blue: 0xC5 / 255),
      Color(red: 0x78 / 255, green: 0x76 / 255, blue: 0x97 / 255),
    ],
    startPoint: .top,
    endPoint: .bottom)

  /// Fixed dark ink contrasts with the same track in both appearances; primary would invert to
  /// white.
  private static let ink = Color(red: 0x1C / 255, green: 0x1B / 255, blue: 0x2A / 255)

  /// Use quieter timestamp ink with the same contrast in both appearances.
  private static let labelInk = Color(red: 0x55 / 255, green: 0x55 / 255, blue: 0x55 / 255)

  /// Clear glass highlights the selection while preserving ruler legibility and the track's
  /// violet colour.
  private var selection: some View {
    let start = viewX(startTime), end = viewX(endTime)
    return Color.clear
      .glassEffect(.clear, in: .rect(cornerRadius: Metrics.selectionCorner))
      .frame(width: max(0, end - start))
      // Keep the darkened channel below timestamps to preserve text contrast.
      .padding(.top, Metrics.labelRow)
      .padding(.bottom, Metrics.selectionInset)
      .offset(x: start)
      .frame(maxWidth: .infinity, alignment: .leading)
      // Clip selection at the track's rounded ends.
      .clipShape(.rect(cornerRadius: Metrics.corner))
  }

  /// Draw ticks over the selection in one Canvas pass.
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

  /// Fixed-width Monaco labels make horizontal placement deterministic.
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
    .foregroundStyle(Self.labelInk)
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
    // Offsets use the full track's centre; a content-sized frame would shift both children.
    .frame(width: Metrics.hit, height: Metrics.trackHeight)
    .contentShape(Rectangle())
    .offset(x: viewX(time) - Metrics.hit / 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .gesture(
      DragGesture(minimumDistance: 0)
        // GestureState clears the origin on cancellation as well as completion.
        .updating($dragOrigin) { _, origin, _ in
          if origin == nil { origin = viewX(time) }
        }
        .onChanged { value in
          // Capture origin once: recomputing from snapped values each frame feeds rounding back
          // into the drag and causes drift.
          guard let origin = dragOrigin else { return }
          move(edge, to: scale.time(atX: origin + value.translation.width - Metrics.inset))
        })
    .pointerStyle(.frameResize(position: edge == .start ? .leading : .trailing))
    // Keep handles out of keyboard focus: their offset layout has ambiguous tab order, and the
    // text fields already provide ordered editing. VoiceOver retains adjustable actions.
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

  /// Maintain minimumSeparation. At an endpoint, clear the field so no trim uses the true
  /// duration and restores its placeholder.
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

  /// Separate handles by at least one drag unit or a hit-target width, whichever is larger, so
  /// both remain selectable.
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

#Preview("40:00 - first ten minutes trimmed") {
  TimelinePreview(duration: .seconds(2400), start: "00:10:00", end: "")
}

/// Short duration exercises 2-second snapping and non-minute labels.
#Preview("16:31") {
  TimelinePreview(duration: .seconds(991), start: "", end: "")
}

/// Verify the final label remains 03:17:43 with a 30-second drag unit.
#Preview("3:17:43") {
  TimelinePreview(duration: .seconds(11863), start: "00:45:00", end: "03:00:00")
}

#Preview("Narrow - three labels") {
  TimelinePreview(duration: .seconds(2400), start: "", end: "", width: 300)
}

/// Invalid typed input dims and disables the timeline; the form shows the error.
#Preview("Dimmed - invalid text") {
  TimelinePreview(duration: .seconds(2400), start: "half an hour", end: "", isDimmed: true)
}
