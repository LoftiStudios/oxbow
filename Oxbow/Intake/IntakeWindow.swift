import AppKit
import SwiftUI
import OxbowKit

/// Paste a link, see what it is, choose which of its outputs you want, and
/// add the job. Every rule this window obeys lives in `IntakeModel`; this is
/// the rendering of it.
///
/// **A window, not a sheet.** A sheet cannot be taller than the window that
/// hosts it, and this form legitimately grew past that with the old render
/// options open — since deleted (docs/design/compositing.md §3, §8), but the
/// shape earned here is kept: a sheet meant either a clipped, scrolling form
/// or a queue window whose minimum size was dictated by its own modal —
/// both of which were tried, and both of which are the tail wagging the dog.
/// A window sizes itself, remembers what the user dragged it to, and closes
/// with ⌘W. This is the shape Transmission uses for the same job.
///
/// `Window` rather than `WindowGroup` in `OxbowApp`, so ⌘N re-focuses the one
/// that exists instead of stacking up five half-filled copies.
///
/// **A `Form`, not a hand-built stack.** The labels, their column, the row
/// spacing and the section grouping are all things macOS has an opinion about,
/// and `.formStyle(.grouped)` is that opinion — the same one System Settings
/// renders with. The previous layout drew its own `Text("Name").font(.caption)`
/// labels above each field and hard-coded a 60pt label column for the trim row,
/// which is how a Mac window ends up looking like a web page.
struct IntakeWindow: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: IntakeModel
  @State private var hostWindow: NSWindow?
  @State private var isAdding = false
  @FocusState private var isLinkFocused: Bool

  init(controller: QueueController) {
    _model = State(initialValue: IntakeModel(controller: controller))
  }

  /// For previews, and for anything else that wants to drive the sheet without
  /// an engine behind it — `IntakeModel`'s own init takes closures for exactly
  /// this reason, and this is what lets a preview reach them.
  init(model: IntakeModel) {
    _model = State(initialValue: model)
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        source

        if model.hasSettledMetadata {
          naming
          // Trim before Download: which part of the video you want is a
          // property of the video, like its name, while Download is about what
          // format to render it in. Ordering it this way also stops the chat
          // options — which appear and disappear — from shoving the trim
          // controls you were just setting down the window.
          // Where it goes, before how much of it you want. The order follows
          // the decision being made: what this is, where to put it, how much
          // of it, then the details of how to render it.
          saveTo
          if model.showsTrimOptions { trim }
          outputs
        }
      }
      .formStyle(.grouped)

      Divider()
      footer
    }
    // A minimum, not a size. The window's own size is the user's business and
    // `.defaultSize` in `OxbowApp` sets where it starts; all this view owes is
    // a floor below which its controls would start colliding.
    .frame(minWidth: 460, minHeight: 320)
    .background(HostWindowReader(window: $hostWindow))
    .defaultFocus($isLinkFocused, true)
    .onAppear(perform: prefillFromClipboard)
    // Turning on chat or trim adds a section to a form whose footer is pinned,
    // so the new section arrives below the fold — the one you just asked for is
    // the one you cannot see. Grow the window to meet it.
    .onChange(of: desiredContentHeight) { _, wanted in grow(toFit: wanted) }
    .onChange(of: hostWindow) { _, _ in grow(toFit: desiredContentHeight) }
    // The scene outlives the window, so closing it has to do what dismissing
    // a sheet would have done for free. See `IntakeModel.reset()`.
    .onDisappear(perform: model.reset)
    // Debounced here rather than in the model so the model stays synchronous
    // to test: `.task(id:)` already cancels the previous fetch when the link
    // changes, and the sleep keeps a half-typed URL from being fetched.
    .task(id: model.linkText) {
      guard model.target != nil else { return }
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      await model.load()
    }
  }

  // MARK: - Sections

  /// The link, and what came back for it.
  private var source: some View {
    Section {
      // A `Form` turns a `TextField`'s first argument into its label, which is
      // not where this belongs — the field is the whole point of the row and
      // wants the hint inside it. `prompt:` is the placeholder, `"Link"` the
      // label VoiceOver reads.
      TextField("Link", text: $model.linkText, prompt: Text("Twitch VOD or clip link"))
        .focused($isLinkFocused)

      if model.isLinkUnrecognized {
        Label("That does not look like a Twitch VOD or clip address.", systemImage: "xmark.circle")
          .font(.callout)
          .foregroundStyle(.red)
      } else if let failure = model.metadataFailure {
        // A failure, not a dead end: the name below has fallen back to the id
        // or slug and the window still works. The card keeps its place so the
        // failure does not also collapse the layout.
        VideoCard(.unavailable(title: model.name))
        Label(failure, systemImage: "exclamationmark.triangle")
          .font(.callout)
          .foregroundStyle(.orange)
      } else if let info = model.info {
        VideoCard(info: info)
      } else if model.target != nil {
        // The link parses, so a fetch is coming. Draw the card now, in its
        // loading state, rather than letting it appear whole when the network
        // answers and shove everything below it down the window.
        VideoCard(.loading)
      }
    }
  }

  private var naming: some View {
    Section {
      TextField("Name", text: $model.name)
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        // What this job will actually write, so the name field is not a guess.
        Text(exampleFilenames)
          .font(.caption)
          .foregroundStyle(.secondary)
        if let collision = model.destinationCollision {
          // Orange, not red: nothing is wrong and nothing is blocked. Red is
          // reserved for `addFailure` below, where the sheet is refusing.
          Label(collisionWarning(for: collision), systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// Names the folder rather than saying "the destination", so the sentence
  /// is checkable at a glance against the folder row further down.
  private func collisionWarning(for collision: URL) -> String {
    let folder = collision.deletingLastPathComponent().lastPathComponent
    return "A file with this name is already in \(folder) — adding this will replace it."
  }

  /// Two choices, not three independent toggles: a chat render in isolation
  /// has little use, and the composite is what makes it worth producing at
  /// all (design doc §3). `DownloadOutput` already narrowed to this pair;
  /// this is just its rendering.
  private var outputs: some View {
    Section("Download") {
      Picker("Output", selection: $model.output) {
        Text(isClip ? "Clip + chat" : "Video + chat").tag(DownloadOutput.videoWithChat)
        Text(isClip ? "Clip" : "Video").tag(DownloadOutput.video)
      }
      .pickerStyle(.radioGroup)
      .labelsHidden()

      // Directly under the picker: the quality is a property of the media
      // download, and nothing else on this sheet reads it.
      Picker("Quality", selection: $model.quality) {
        Text("Best available").tag("")
        ForEach(model.qualities, id: \.name) { quality in
          Text(model.label(for: quality)).tag(quality.name)
        }
      }

      // `chatProblem == nil` as well as the output: offering a text size for
      // chat that cannot be downloaded, above a row explaining that it
      // cannot, is a control for something that will never happen.
      if model.output == .videoWithChat, model.chatProblem == nil {
        // The one control the deleted render-options form left behind (see
        // docs/design/compositing.md §4, §8): a fixed size cannot serve both
        // a laptop window and a TV across the room. "Small"/"Medium"/"Large"
        // does not explain itself the way "Video + chat"/"Video" does above,
        // so — unlike that picker — this one keeps its label on screen.
        Picker("Chat text size", selection: $model.chatSize) {
          Text("Small").tag(ChatSize.small)
          Text("Medium").tag(ChatSize.medium)
          Text("Large").tag(ChatSize.large)
        }
        .pickerStyle(.segmented)

        // Not decoration: a six-hour stream is roughly 75 minutes of
        // encoding, and a user who is not told that reads a busy queue as a
        // hang.
        Text("Chat is rendered in a column beside the video and encoded into "
          + "one file. This takes roughly as long as the stream itself.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      // A clip whose parent broadcast Twitch has expired, or any video whose
      // metadata fetch failed — see `IntakeModel.chatProblem`. Without this
      // the sheet would simply grey Add out with nothing on screen saying
      // why, which is the exact failure `compositeProblem` below exists to
      // prevent.
      if let chatProblem = model.chatProblem {
        Label(chatProblem, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }

      // Only reachable for a clip whose selected rendition Twitch never
      // recorded pixel dimensions for — see `IntakeModel.compositeProblem`.
      // Shown the same way the trim section shows its own refusal reason.
      if let compositeProblem = model.compositeProblem {
        Label(compositeProblem, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  /// The timeline needs a duration to scale against, so a VOD whose metadata
  /// fetch failed falls back to the two fields alone — which is the state the
  /// `Metadata failed` preview below already reaches, since `showsTrimOptions`
  /// keys off the parsed link rather than off `info`.
  private var trim: some View {
    Section {
      // Closing this undoes nothing — it hides the controls and that is all.
      // Which is why the label carries the range: a section quietly applying a
      // trim while showing nothing would be exactly the hidden state a
      // disclosure triangle is so easily mistaken for.
      DisclosureGroup(isExpanded: $model.isTrimExpanded) {
        if let duration = model.info?.duration {
          TrimTimeline(
            duration: duration,
            startText: $model.trimStartText,
            endText: $model.trimEndText,
            isDimmed: model.trimIsInvalid)
        }

        // One row, not three. As separate `LabeledContent` rows these pushed
        // the section below the fold of the default window, and they read as
        // three unrelated settings rather than as the two ends of one range
        // with its length between them.
        HStack(spacing: 8) {
          Text("Start")
            .foregroundStyle(.secondary)
          TextField("Start", text: $model.trimStartText, prompt: Text("0:00"))
            .labelsHidden()
            .monospacedDigit()
            .frame(width: 88)

          Spacer(minLength: 8)
          if let selected = model.effectiveDuration {
            // Not a field: it is derived from the two that are, and giving it
            // a box would invite people to type into it.
            Text(Timecode.spelled(selected))
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
          Spacer(minLength: 8)

          Text("End")
            .foregroundStyle(.secondary)
          // Trailing-aligned and sized to its contents, unlike Start. This is
          // the right-hand end of the range and it sits under the right-hand
          // end of the timeline, so it stays anchored there whatever it holds
          // — in a fixed-width box the long `End of video` placeholder reached
          // the edge while a typed `07:13:00` stopped short of it, and the
          // label was left stranded across a gap that changed size with the
          // value. `minWidth` keeps a half-typed value from shrinking the
          // field to something too small to click back into, and monospaced
          // digits stop the label twitching as the digits change under a drag.
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
      } label: {
        HStack(spacing: 8) {
          Text("Trim")
          if let summary = model.trimSummary {
            Text(summary)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        }
      }
    }
  }

  /// The destination and the buttons, pinned below the form.
  ///
  /// **Outside the scroll view, deliberately.** As a `Section` at the bottom
  /// of the form it scrolled away the moment a thumbnail loaded, so the one
  /// thing every download commits to — where the file goes — was below the
  /// fold exactly when the window looked most finished. Transmission pins its
  /// path row above its buttons for the same reason.
  /// Only the buttons now. The destination moved up into the form, into the
  /// order the decision is actually made in. Pinning it here was a guard
  /// against it falling below the fold exactly when the form looked most
  /// finished — which the window growing to fit its own sections now covers.
  private var footer: some View {
    buttons
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
  }

  private var saveTo: some View {
    Section {
      destination
    } footer: {
      if let warning = model.spaceWarning {
        VStack(alignment: .leading, spacing: 2) {
          // Orange, matching the overwrite caution under the name field:
          // nothing is wrong and nothing is blocked. Red belongs to
          // `addFailure`, where the sheet is actually refusing.
          Label(spaceWarningText(warning), systemImage: "externaldrive.badge.exclamationmark")
            .font(.caption)
            .foregroundStyle(.orange)
          if let remedy = warning.remedy {
            // The actionable half, and the reason this is a warning worth
            // showing at all. Indented under the label's text rather than its
            // icon so the two read as one block.
            Text(remedyText(remedy))
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.leading, 18)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  /// Both figures on one line, and the volume named rather than called "the
  /// disk" — a Mac with an external drive attached has more than one, and
  /// which one is short is the first thing the user needs to know.
  ///
  /// "About", because it is: `docs/design/disk-preflight.md` §3.2 is explicit
  /// that the composite term is a median of four samples. Stating a soft
  /// number as though it were exact is how a warning earns distrust.
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
        .foregroundStyle(.secondary)

      if let folder = model.folder {
        // The real Finder icon for the real folder: a faster read than the
        // path text, and proof the path resolves to something.
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
      // Named for what it does. No ellipsis: nothing further is asked for —
      // the warning above is the whole disclosure, and this button completes
      // the action (HIG reserves the ellipsis for actions that need more
      // input).
      Button(model.destinationCollision == nil ? "Add" : "Replace") { add() }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canAdd || isAdding)
    }
  }

  // MARK: - Growing to fit

  /// How much room the form wants for what is currently on screen.
  ///
  /// **Floors, not layout arithmetic.** These are deliberately approximate: the
  /// window is only ever grown, never shrunk, so an over-estimate costs a
  /// little slack under the last row and an under-estimate leaves the form
  /// scrolling as it does today. Measuring the real content height would mean
  /// reaching inside a `Form`'s scroll view, which SwiftUI does not offer and
  /// which would break the moment the form style changed.
  private var desiredContentHeight: CGFloat {
    var height: CGFloat = 600
    guard model.hasSettledMetadata else { return height }
    if model.output == .videoWithChat, model.chatProblem == nil { height += 120 }
    if model.showsTrimOptions, model.isTrimExpanded { height += 165 }
    return height
  }

  /// Extends the window's **bottom** edge to make room, never its top.
  ///
  /// The title bar staying put is the point: the window appears to unfold
  /// downward from where you left it, rather than jumping under the cursor. It
  /// stops at the bottom of the screen and never shrinks — a window the user
  /// has sized up is theirs, and collapsing a section is not a request to lose
  /// that space.
  private func grow(toFit wanted: CGFloat) {
    guard let hostWindow, let screen = hostWindow.screen ?? NSScreen.main else { return }
    let chrome = hostWindow.frame.height - hostWindow.contentLayoutRect.height
    let target = min(wanted + chrome, screen.visibleFrame.height)
    let delta = target - hostWindow.frame.height
    guard delta > 0 else { return }

    var frame = hostWindow.frame
    frame.size.height = target
    frame.origin.y = max(frame.origin.y - delta, screen.visibleFrame.minY)
    hostWindow.setFrame(frame, display: true, animate: true)
  }

  // MARK: - Actions

  /// Dismisses only once the job is in the engine. `model.add()` awaits the
  /// enqueue all the way in and reports whether it landed; a refusal leaves
  /// the sheet open with its reason on screen.
  private func add() {
    isAdding = true
    Task {
      let didAdd = await model.add()
      isAdding = false
      if didAdd { dismiss() }
    }
  }

  /// Fills the link field from the clipboard, when it holds a Twitch address
  /// and the field is still empty.
  ///
  /// The reason the window exists is almost always a link you just copied, so
  /// having to paste it is a keystroke asking to be skipped. Guarded on
  /// `TwitchLink.parse` rather than on any string, so an unrelated clipboard
  /// never lands in the field — and on `linkText` being empty, so re-focusing
  /// the window cannot overwrite something half-typed.
  private func prefillFromClipboard() {
    guard model.linkText.isEmpty else { return }
    guard let text = NSPasteboard.general.string(forType: .string),
          TwitchLink.parse(text) != nil
    else { return }
    model.linkText = text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.directoryURL = try? FileManager.default.url(
      for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)

    // A sheet on the sheet. `runModal()` here would stack an app-modal panel
    // on top of a sheet — it appears detached from the window it belongs to,
    // and it spins a nested runloop underneath SwiftUI.
    guard let hostWindow else {
      // Only if the window has not been read back yet, which cannot happen
      // once the sheet is on screen and the user has clicked a button in it.
      if panel.runModal() == .OK { model.folder = panel.url }
      return
    }
    panel.beginSheetModal(for: hostWindow) { response in
      if response == .OK { model.folder = panel.url }
    }
  }

  // MARK: - Text

  private var isClip: Bool {
    if case .clip = model.target { return true }
    return false
  }

  /// What this job will actually write, so the name field is not a guess.
  ///
  /// One line always: `.video` and `.videoWithChat` both produce exactly one
  /// file, sharing the same suffix — a composite replaces the video it
  /// stacks rather than accompanying it.
  private var exampleFilenames: String {
    model.outputBaseName + OutputSuffix.video
  }

}

/// Hands back the AppKit window hosting this SwiftUI view.
///
/// `NSSavePanel.beginSheetModal(for:)` needs the sheet's own `NSWindow`, and
/// SwiftUI does not expose it. Zero-sized and in the background, so it
/// affects nothing it is placed behind; the state write is deferred a turn
/// because `makeNSView` runs during a view update, and `view.window` is nil
/// until the view is in a window anyway.
private struct HostWindowReader: NSViewRepresentable {
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

/// A model wired to a canned fetch, so the previews below show the sheet's
/// settled states without an engine, a helper, or a network call.
///
/// The link is pre-filled and the sheet's own `.task(id:)` runs in a preview,
/// so each of these loads through the real `IntakeModel.load()` path rather
/// than having its state poked in from outside.
@MainActor
private func previewModel(
  link: String = "https://www.twitch.tv/videos/2844548319",
  info: VideoInfo? = .previewVOD,
  folder: URL? = URL(filePath: "/Users/you/Downloads"),
  fileExists: @escaping (URL) -> Bool = { _ in false },
  volumeSpace: VolumeSpace = .previewFull(free: 10_000_000_000_000))
  -> IntakeModel
{
  let model = IntakeModel(
    fetchInfo: { _ in
      guard let info else { throw VideoInfoFetchError.unparseableOutput(snippet: "") }
      return info
    },
    enqueue: { _, _ in },
    fileExists: fileExists,
    volumeSpace: volumeSpace,
    // Previews render off-screen and are never exercised by `xcodebuild
    // test`, so reaching `.standard` here costs nothing the way it would in
    // a test run — and `folder` is overwritten just below regardless.
    preferences: Preferences())
  model.linkText = link
  model.folder = folder
  return model
}

extension VolumeSpace {
  /// A volume with a fixed amount of room. Every preview uses one rather than
  /// `.live`, so a preview renders the same way on a full laptop and an empty
  /// one — a canvas that changes with the developer's disk is a canvas nobody
  /// can review.
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
    thumbnailURL: URL(string: """
      https://static-cdn.jtvnw.net/cf_vods/d2nvs31859zcd8/\
      5652d9d62faa525b5c68_leighxp_317872278872_1786573193//thumb/thumb0-320x180.jpg
      """))
}

/// The sheet as it opens: chat included, since that is the default.
#Preview("Video + chat") {
  IntakeWindow(model: previewModel())
}

#Preview("Video") {
  let model = previewModel()
  model.output = .video
  return IntakeWindow(model: model)
}

/// Exercises the chat text size picker away from its `.medium` default, so a
/// glance at this preview catches the segmented control rendering wrong as
/// readily as the "Video + chat" one above catches everything else in the
/// section.
#Preview("Video + chat - large text") {
  let model = previewModel()
  model.chatSize = .large
  return IntakeWindow(model: model)
}

/// A clip whose parent broadcast Twitch has expired, with chat asked for.
/// Exercises `IntakeModel.chatProblem`: the chat size picker and its encoding
/// note are suppressed, the refusal is shown in their place, and Add is
/// disabled — while `.video` remains selectable, because the clip itself
/// still downloads.
#Preview("Clip + chat - broadcast gone") {
  let clipInfo = VideoInfo(
    streamer: "f00xtr0t323",
    title: "This dude jumped off the ledge.",
    createdAt: .now,
    duration: .seconds(30),
    qualities: [
      StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_264_272),
    ],
    thumbnailURL: nil,
    hasDownloadableChat: false)
  let model = previewModel(
    link: "https://clips.twitch.tv/AdorableStylishPotatoPlanking-5UAS4GFYHTkDW4xX",
    info: clipInfo)
  model.output = .videoWithChat
  return IntakeWindow(model: model)
}

/// A clip old enough that Twitch never backfilled pixel dimensions onto its
/// only rendition, explicitly chosen for a composite. Exercises
/// `IntakeModel.compositeProblem`, the one conditional row nothing else here
/// renders.
#Preview("Video + chat - composite problem") {
  let clipInfo = VideoInfo(
    streamer: "LeighXP",
    title: "an old clip with no recorded dimensions",
    createdAt: .now,
    duration: .seconds(45),
    qualities: [
      StreamQuality(name: "720p0-1", resolution: "", bitsPerSecond: 0),
    ],
    thumbnailURL: nil)
  let model = previewModel(link: "https://clips.twitch.tv/TangibleGiantPancakeKappa", info: clipInfo)
  model.output = .videoWithChat
  model.quality = "720p0-1"
  return IntakeWindow(model: model)
}

#Preview("Empty") {
  IntakeWindow(model: previewModel(link: "", info: nil, folder: nil))
}

/// Also the second half of `IntakeModel.chatProblem`: without metadata the
/// default output cannot be built, so this preview shows the refusal and a
/// disabled Add alongside the id-derived fallback name.
#Preview("Metadata failed") {
  IntakeWindow(model: previewModel(info: nil))
}

/// A name whose file is already sitting in the chosen folder. Exercises the
/// caution line under the name field and the Add button's relabelling — the
/// two halves of the overwrite warning, which have to appear together.
#Preview("Name already taken") {
  IntakeWindow(model: previewModel(fileExists: { _ in true }))
}

/// A destination that cannot hold the job, with a lower rendition that can.
/// Unreachable in a preview without a genuinely full disk, which is exactly
/// why it needs one — this is the layout nobody would otherwise look at until
/// a user hit it.
#Preview("Not enough room - with a remedy") {
  IntakeWindow(model: previewModel(volumeSpace: .previewFull(free: 900_000_000)))
}

/// The same warning with no way out: every rendition on offer is too big, so
/// the second line is absent and the first has to stand on its own.
#Preview("Not enough room - no remedy") {
  IntakeWindow(model: previewModel(volumeSpace: .previewFull(free: 1_000_000)))
}

/// The timeline in the window it actually lives in, at a real VOD's length,
/// with a trim set. The section is otherwise only reachable by clicking.
#Preview("Video - trimmed") {
  let model = previewModel()
  model.output = .video
  model.isTrimExpanded = true
  model.trimStartText = "00:02:00"
  return IntakeWindow(model: model)
}
