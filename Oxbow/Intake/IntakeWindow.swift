import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OxbowKit

/// IntakeModel supplies state and validation. A single Window sizes independently of the queue
/// and lets ⌘N refocus an existing intake.
struct IntakeWindow: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: IntakeModel
  @State private var hostWindow: NSWindow?
  @State private var isAdding = false
  @FocusState private var isLinkFocused: Bool

  /// Consume and clear the pending finding so it cannot reappear on the next open.
  @Binding private var pendingIntake: PendingIntake?

  init(controller: QueueController, pendingIntake: Binding<PendingIntake?>) {
    _model = State(initialValue: IntakeModel(controller: controller))
    _pendingIntake = pendingIntake
  }

  /// Injected model supports previews without an engine; no pending hand-off by default.
  init(model: IntakeModel, pendingIntake: Binding<PendingIntake?> = .constant(nil)) {
    _model = State(initialValue: model)
    _pendingIntake = pendingIntake
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        source

        if model.hasSettledMetadata {
          // Keep trim above options so changing chat controls does not move the active trim
          // section.
          if model.showsTrimOptions { trim }
          options
        }
      }
      .formStyle(.grouped)

      Divider()
      footer
    }
    .frame(minWidth: 460, minHeight: 320)
    .background(HostWindowReader(window: $hostWindow))
    .defaultFocus($isLinkFocused, true)
    // Reload preferences before applying pending input or clipboard prefill.
    .onAppear {
      model.reseedFromPreferences()
      // Seed the fixture through the normal debounced fetch path, before clipboard prefill.
      #if DEBUG
      if let link = ScreenshotFixture.link { model.linkText = link }
      #endif
      // A selected finding takes precedence over the clipboard. Clear it immediately after
      // applying.
      if let pendingIntake {
        model.apply(pendingIntake)
        self.pendingIntake = nil
      } else {
        prefillFromClipboard()
      }
    }
    // Open fixture trim after load() resets it; name assignment signals that metadata has
    // settled.
    #if DEBUG
    .onChange(of: model.name) { _, newName in
      guard ScreenshotFixture.opensTrim, !newName.isEmpty else { return }
      model.isTrimExpanded = true
    }
    #endif
    // Resize to expose newly expanded controls above the pinned footer.
    .onChange(of: desiredContentHeight) { _, wanted in resize(toFit: wanted) }
    .onChange(of: hostWindow) { _, _ in resize(toFit: desiredContentHeight) }
    // The scene retains its model after close; reset per-video state.
    .onDisappear(perform: model.reset)
    // Debounce in the view; task(id:) cancels superseded fetches while model tests can call
    // load() directly.
    .task(id: model.linkText) {
      guard model.target != nil else { return }
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      await model.load()
    }
  }

  // MARK: - Sections

  private var source: some View {
    Section {
      // Use prompt for the visible hint and retain Link as the accessibility label.
      TextField("Link", text: $model.linkText, prompt: Text("Twitch VOD or clip link"))
        .focused($isLinkFocused)

      if model.isLinkUnrecognized {
        Label("That does not look like a Twitch VOD or clip address.", systemImage: "xmark.circle")
          .font(.callout)
          .foregroundStyle(.red)
      } else if let failure = model.metadataFailure {
        // Keep the card's space on failure; video-only can still use the id-derived name.
        VideoCard(.unavailable(title: model.name))
        Label(failure, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .foregroundStyle(.orange)
      } else if let info = model.info {
        VideoCard(info: info)
      } else if model.target != nil {
        // Reserve the card's space before metadata arrives.
        VideoCard(.loading)
      }
    }
  }

  /// Name the folder to match the destination row and collapsed summary.
  private func collisionWarning(for collision: URL) -> String {
    let folder = collision.deletingLastPathComponent().lastPathComponent
    return "A file with this name is already in \(folder) — adding this will replace it."
  }

  /// Collapsible download settings; see docs/design/settings.md §2. The summary exposes the
  /// destination, blocking errors force expansion, and disk/collision warnings remain outside.
  /// The encode-duration note stays inside with its related controls.
  @ViewBuilder
  private var options: some View {
    Section {
      disclosureHeader(
        "Download Options",
        isExpanded: model.isOptionsEffectivelyExpanded,
        trailing: {
          if !model.isOptionsEffectivelyExpanded {
            Text(model.optionsSummary)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        },
        toggle: { model.isOptionsEffectivelyExpandedBinding.toggle() })

      if model.isOptionsEffectivelyExpanded {
        Picker("Download", selection: $model.output) {
          Text(isClip ? "Clip + chat" : "Video + chat").tag(DownloadOutput.videoWithChat)
          Text(isClip ? "Clip" : "Video").tag(DownloadOutput.video)
        }

        // Route selection through selectQuality so an explicit pick updates the saved cap.
        Picker("Quality", selection: qualityBinding) {
          Text("Best available").tag("")
          ForEach(model.qualities, id: \.name) { quality in
            Text(model.label(for: quality)).tag(quality.name)
          }
        }

        // Hide chat sizing when chat cannot be downloaded.
        if model.output == .videoWithChat, model.chatProblem == nil {
          Picker("Chat text size", selection: $model.chatSize) {
            Text("Small").tag(ChatSize.small)
            Text("Medium").tag(ChatSize.medium)
            Text("Large").tag(ChatSize.large)
          }
        }

        destination

        // The collapsed summary already exposes the fallback folder; keep its explanation
        // inside options.
        if model.destinationFellBack {
          Label(
            "The folder you last chose is not available, so Oxbow will use "
              + "Downloads.",
            systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let chatProblem = model.chatProblem {
          Label(chatProblem, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
        }

        if let compositeProblem = model.compositeProblem {
          Label(compositeProblem, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
        }

        // Wrap the checkbox and label together so Form does not move the glyph into the
        // trailing value column.
        HStack {
          // A checkbox represents this submission's opt-in, rather than a persistent mode.
          Toggle(isOn: $model.wantsToSaveDefaults) {
            Text("Make these settings my defaults")
          }
          .toggleStyle(.checkbox)
          Spacer(minLength: 0)
        }

        // Separate the encode note from the checkbox label.
        if model.output == .videoWithChat, model.chatProblem == nil {
          Text("Chat is rendered in a column beside the video and encoded into "
            + "one file. This takes roughly as long as the stream itself.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }

        if model.wantsToSaveDefaults {
          Text(saveNote)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }

    // Warnings stay outside the disclosure. Omit the Section entirely when empty to avoid a
    // blank grouped box.
    if model.destinationCollision != nil || model.spaceWarning != nil {
      Section {
      VStack(alignment: .leading, spacing: 8) {
        if let collision = model.destinationCollision {
          // Orange marks advisory warnings; red is reserved for refusals.
          Label(collisionWarning(for: collision), systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }

        if let warning = model.spaceWarning {
          VStack(alignment: .leading, spacing: 2) {
            Label(spaceWarningText(warning), systemImage: "externaldrive.badge.exclamationmark")
              .font(.caption)
              .foregroundStyle(.orange)
            if let remedy = warning.remedy {
              Text(remedyText(remedy))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 18)
            }
          }
        }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  /// Routed through the model so a pick re-derives the cap (§3.3).
  private var qualityBinding: Binding<String> {
    Binding(get: { model.quality }, set: { model.selectQuality($0) })
  }

  /// Explain any differences between visible choices and saved defaults.
  private var saveNote: String {
    var parts: [String] = []
    if let rung = model.savedQualityNote { parts.append("Saved as \(rung.label).") }
    if model.withholdsOutputFromSave {
      parts.append("Whether to include chat will not be saved from this video.")
    }
    if model.withholdsChatSizeFromSave {
      parts.append("Chat text size will not be saved from this video.")
    }
    parts.append("You can change these any time in Settings.")
    return parts.joined(separator: " ")
  }

  /// Without metadata duration, show time fields without the timeline.
  private var trim: some View {
    // Collapsing preserves the trim; the header continues to show its range.
    Section {
      disclosureHeader(
        "Trim",
        isExpanded: model.isTrimExpanded,
        trailing: {
          if let summary = model.trimSummary {
            Text(summary)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        },
        toggle: { model.isTrimExpanded.toggle() })

      if model.isTrimExpanded {
        if let duration = model.info?.duration {
          TrimTimeline(
            duration: duration,
            startText: $model.trimStartText,
            endText: $model.trimEndText,
            isDimmed: model.trimIsInvalid)
        }

        // Keep the range endpoints and derived duration on one row.
        HStack(spacing: 8) {
          Text("Start")
            .foregroundStyle(.secondary)
          TextField("Start", text: $model.trimStartText, prompt: Text("0:00"))
            .labelsHidden()
            .monospacedDigit()
            .frame(width: 88)

          Spacer(minLength: 8)
          if let selected = model.effectiveDuration {
            Text(Timecode.spelled(selected))
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
          Spacer(minLength: 8)

          Text("End")
            .foregroundStyle(.secondary)
          // Anchor End to the timeline's trailing edge. A minimum width keeps partial input
          // clickable; monospaced digits prevent movement during dragging.
          TextField("End", text: $model.trimEndText, prompt: Text("End of video"))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .fixedSize()
            .frame(minWidth: 64, alignment: .trailing)
        }
        if model.trimIsInvalid {
          Label(
            "Use h:mm:ss, m:ss, or seconds. The end must come after the start, "
              + "and both must fall inside the video.",
            systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    }
  }

  /// Pin action buttons outside the scrolling form.
  private var footer: some View {
    buttons
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
  }

  /// Name the affected volume and label the estimate approximate.
  private func spaceWarningText(_ warning: IntakeModel.SpaceWarning) -> String {
    let needed = warning.needed.formatted(.byteCount(style: .file))
    let available = warning.available.formatted(.byteCount(style: .file))
    return "Needs about \(needed) · \(available) free on \(warning.volumeName)"
  }

  private func remedyText(_ remedy: IntakeModel.SpaceWarning.Remedy) -> String {
    "\(remedy.qualityName) would need about \(remedy.needed.formatted(.byteCount(style: .file)))"
  }

  private var destination: some View {
    HStack(spacing: 8) {
      Text("Save to")

      if let folder = model.folder {
        Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path(percentEncoded: false)))
          .resizable()
          .frame(width: 16, height: 16)
        Text(folder.lastPathComponent)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(folder.path(percentEncoded: false))
      } else {
        Text("No folder chosen")
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 8)
      Button("Choose…") { chooseFolder() }
        .controlSize(.small)
    }
  }

  private var buttons: some View {
    HStack(spacing: 12) {
      if let addFailure = model.addFailure {
        Label(addFailure, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      if isAdding { ProgressView().controlSize(.small) }
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      // Replace explicitly authorizes the displayed collision; no additional input follows.
      Button(model.destinationCollision == nil ? "Add" : "Replace") { add() }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canAdd || isAdding)
    }
  }

  // MARK: - Sizing to fit

  /// Estimated content heights control both growth and shrinkage. Verify changes on screen:
  /// excess leaves gaps, shortfall causes scrolling.
  private var desiredContentHeight: CGFloat {
    // Measured with a two-line title and both sections collapsed.
    var height: CGFloat = 640
    // Size when the link parses to avoid a second animated resize when metadata arrives.
    guard model.target != nil else { return height }
    if model.output == .videoWithChat, model.chatProblem == nil,
       model.isOptionsEffectivelyExpanded
    {
      // Measured expanded options height, including destination, defaults, chat sizing, and
      // encode note.
      height += 230
    }
    if model.showsTrimOptions, model.isTrimExpanded { height += 100 }
    return height
  }

  /// Use a full-width button with our own chevron: Section(isExpanded:)'s chevron sits outside
  /// the clickable header bounds.
  private func disclosureHeader(
    _ title: String,
    isExpanded: Bool,
    @ViewBuilder trailing: () -> some View,
    toggle: @escaping () -> Void)
    -> some View
  {
    Button {
      toggleDisclosure(toggle)
    } label: {
      // Align body and caption text by baseline; give the chevron its own optical alignment.
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
          // Rotate one glyph for a continuous disclosure transition.
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .frame(width: 10)
        Text(title)
        trailing()
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  /// Share timing between the disclosure animation and window frame change.
  private static let disclosureDuration: Double = 0.22

  /// Toggle first, then read desiredContentHeight so content and window animate to the same
  /// state.
  private func toggleDisclosure(_ toggle: () -> Void) {
    withAnimation(.easeInOut(duration: Self.disclosureDuration)) { toggle() }
    resize(toFit: desiredContentHeight)
  }

  /// Resize from the bottom edge, keeping the title bar fixed. Both opening and closing
  /// disclosures override the current height to fit content.
  private func resize(toFit wanted: CGFloat) {
    guard let hostWindow, let screen = hostWindow.screen ?? NSScreen.main else { return }
    let chrome = hostWindow.frame.height - hostWindow.contentLayoutRect.height
    let target = min(wanted + chrome, screen.visibleFrame.height)
    let delta = target - hostWindow.frame.height
    // A point either way is not worth an animation.
    guard abs(delta) > 1 else { return }

    var frame = hostWindow.frame
    frame.size.height = target
    frame.origin.y = max(frame.origin.y - delta, screen.visibleFrame.minY)

    // Use explicit timing to match the content animation; setFrame's automatic duration varies
    // with distance.
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.disclosureDuration
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      hostWindow.animator().setFrame(frame, display: true)
    }
  }

  // MARK: - Actions

  /// Use IntakeAdd to record manual submissions too. Save defaults and dismiss only after
  /// enqueue succeeds; QueueHost supplies no live recording handle during tests.
  private func add() {
    isAdding = true
    Task {
      let didAdd = await IntakeAdd.perform(
        model,
        recording: QueueHost.shared.videoRecording,
        helperVersion: AboutInfo.main.helperVersion)
      isAdding = false
      if didAdd {
        // Only after the enqueue succeeds: on the addFailure path the window stays open
        // on a job that was never composed, and saving there would persist the settings
        // of a job that does not exist.
        model.saveDefaultsIfRequested()
        dismiss()
      }
    }
  }

  /// Prefill only an empty field with a recognized Twitch link; refocusing must preserve typed
  /// input.
  private func prefillFromClipboard() {
    guard model.linkText.isEmpty else { return }
    guard let text = NSPasteboard.general.string(forType: .string),
          TwitchLink.parse(text) != nil
    else { return }
    model.linkText = text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Use a Save panel to choose both folder and filename. Seed it with the current destination
  /// and final .mp4 name, restricting output to that type.
  private func chooseFolder() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = model.outputBaseName + OutputSuffix.video
    panel.directoryURL = model.folder
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.mpeg4Movie]

    // Attach the panel to the intake window to avoid an app-modal nested run loop.
    guard let hostWindow else {
      // Fallback when the host window has not yet been captured.
      if panel.runModal() == .OK, let url = panel.url {
        applyChosenDestination(url)
      }
      return
    }
    panel.beginSheetModal(for: hostWindow) { response in
      guard response == .OK, let url = panel.url else { return }
      applyChosenDestination(url)
    }
  }

  /// Split the chosen URL into folder and base name; outputBaseName still applies sanitization
  /// and suffix limits.
  private func applyChosenDestination(_ url: URL) {
    model.folder = url.deletingLastPathComponent()
    model.name = url.deletingPathExtension().lastPathComponent
  }

  // MARK: - Text

  private var isClip: Bool { model.isClip }

}

/// Capture the hosting NSWindow for sheet panels. Defer the state write until after the view
/// update and window attachment. Shared with SettingsView.
struct HostWindowReader: NSViewRepresentable {
  @Binding var window: NSWindow?

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async { window = view.window }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    guard window !== view.window else { return }
    DispatchQueue.main.async { window = view.window }
  }
}

// MARK: - Previews

/// Canned fetches exercise the normal IntakeModel.load() path in previews.
@MainActor
private func previewModel(
  link: String = "https://www.twitch.tv/videos/2844548319",
  info: VideoInfo? = .previewVOD,
  folder: URL? = URL(filePath: "/Users/you/Downloads"),
  fileExists: @escaping (URL) -> Bool = { _ in false },
  volumeSpace: VolumeSpace = .previewFull(free: 10_000_000_000_000),
  optionsExpanded: Bool = true)
  -> IntakeModel
{
  // Give each preview fresh in-memory preferences to avoid shared state and writes to the
  // user's domain.
  var preferences = Preferences(
    store: InMemoryPreferenceStore(),
    homeDirectory: URL(filePath: "/Users/preview"),
    directoryExists: { _ in true })
  // Seed expansion before constructing the model.
  preferences.optionsPanelIsExpanded = optionsExpanded

  let model = IntakeModel(
    fetchInfo: { _ in
      guard let info else { throw VideoInfoFetchError.unparseableOutput(snippet: "") }
      return VideoInfoFetcher.Fetched(info: info, payload: "")
    },
    enqueue: { _, _ in },
    fileExists: fileExists,
    volumeSpace: volumeSpace,
    preferences: preferences)
  model.linkText = link
  model.folder = folder
  return model
}

extension VolumeSpace {
  /// Fixed capacity keeps previews independent of the developer's disk.
  fileprivate static func previewFull(free: Int64) -> VolumeSpace {
    VolumeSpace(
      availableBytes: { _ in free },
      volumeRoot: { _ in URL(filePath: "/") },
      volumeName: { _ in "Macintosh HD" })
  }
}

extension VideoInfo {
  fileprivate static let previewVOD = VideoInfo(
    streamer: "LeighXP",
    title: "indie horror + something else later?? ٩(◕‿◕)۶",
    createdAt: .now,
    duration: .seconds(991),
    qualities: [
      StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_184_466),
      StreamQuality(name: "720p60", resolution: "1280x720", bitsPerSecond: 3_411_940),
      StreamQuality(name: "480p30", resolution: "852x480", bitsPerSecond: 1_427_697),
    ],
    thumbnailURLs: [URL(string: """
      https://static-cdn.jtvnw.net/cf_vods/d2nvs31859zcd8/\
      5652d9d62faa525b5c68_leighxp_317872278872_1786573193//thumb/thumb0-320x180.jpg
      """)!])
}

#Preview("Video + chat") {
  IntakeWindow(model: previewModel())
}

#Preview("Video") {
  let model = previewModel()
  model.output = .video
  return IntakeWindow(model: model)
}

#Preview("Video + chat - large text") {
  let model = previewModel()
  model.chatSize = .large
  return IntakeWindow(model: model)
}

/// Missing broadcast chat disables Add but leaves video-only selectable.
#Preview("Clip + chat - broadcast gone") {
  let clipInfo = VideoInfo(
    streamer: "f00xtr0t323",
    title: "This dude jumped off the ledge.",
    createdAt: .now,
    duration: .seconds(30),
    qualities: [
      StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_264_272),
    ],
    thumbnailURLs: [],
    hasDownloadableChat: false)
  let model = previewModel(
    link: "https://clips.twitch.tv/AdorableStylishPotatoPlanking-5UAS4GFYHTkDW4xX",
    info: clipInfo)
  model.output = .videoWithChat
  return IntakeWindow(model: model)
}

/// Explicitly select a clip rendition without dimensions to exercise compositeProblem.
#Preview("Video + chat - composite problem") {
  let clipInfo = VideoInfo(
    streamer: "LeighXP",
    title: "an old clip with no recorded dimensions",
    createdAt: .now,
    duration: .seconds(45),
    qualities: [
      StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0),
    ],
    thumbnailURLs: [])
  let model = previewModel(link: "https://clips.twitch.tv/TangibleGiantPancakeKappa", info: clipInfo)
  model.output = .videoWithChat
  model.quality = "720p0-1"
  return IntakeWindow(model: model)
}

#Preview("Empty") {
  IntakeWindow(model: previewModel(link: "", info: nil, folder: nil))
}

/// Failed metadata prevents the default composite but retains the id-derived name.
#Preview("Metadata failed") {
  IntakeWindow(model: previewModel(info: nil))
}

/// The collision warning and Replace button must appear together.
#Preview("Name already taken") {
  IntakeWindow(model: previewModel(fileExists: { _ in true }))
}

#Preview("Not enough room - with a remedy") {
  IntakeWindow(model: previewModel(volumeSpace: .previewFull(free: 900_000_000)))
}

#Preview("Not enough room - no remedy") {
  IntakeWindow(model: previewModel(volumeSpace: .previewFull(free: 1_000_000)))
}

#Preview("Video - trimmed") {
  let model = previewModel()
  model.output = .video
  model.isTrimExpanded = true
  model.trimStartText = "00:02:00"
  return IntakeWindow(model: model)
}

// MARK: - The options panel (§2.1, §2.5-§2.7)

#Preview("Options panel - collapsed") {
  IntakeWindow(model: previewModel(optionsExpanded: false))
}

/// Seed a 720p cap against a video offering only 1080p. Let load() resolve the rendition;
/// selecting before metadata arrives would be ignored. The footnote must still say the saved
/// cap is 720p.
#Preview("Options panel - expanded, ticked, bucket footnote") {
  let info = VideoInfo(
    streamer: "LeighXP",
    title: "indie horror + something else later?? ٩(◕‿◕)۶",
    createdAt: .now,
    duration: .seconds(991),
    qualities: [
      StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_184_466),
    ],
    thumbnailURLs: [])
  let model = previewModel(info: info, optionsExpanded: true)
  model.qualityCap = .p720
  model.wantsToSaveDefaults = true
  return IntakeWindow(model: model)
}

/// Start collapsed to verify that chatProblem alone forces the explanation open.
#Preview("Options panel - forced open by chatProblem") {
  let clipInfo = VideoInfo(
    streamer: "f00xtr0t323",
    title: "This dude jumped off the ledge.",
    createdAt: .now,
    duration: .seconds(30),
    qualities: [
      StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_264_272),
    ],
    thumbnailURLs: [],
    hasDownloadableChat: false)
  let model = previewModel(
    link: "https://clips.twitch.tv/AdorableStylishPotatoPlanking-5UAS4GFYHTkDW4xX",
    info: clipInfo, optionsExpanded: false)
  model.output = .videoWithChat
  return IntakeWindow(model: model)
}
