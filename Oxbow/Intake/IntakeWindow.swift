import AppKit
import SwiftUI
import OxbowKit

/// Paste a link, see what it is, choose which of its outputs you want, and
/// add the job. Every rule this window obeys lives in `IntakeModel`; this is
/// the rendering of it.
///
/// **A window, not a sheet.** A sheet cannot be taller than the window that
/// hosts it, and this form legitimately is: with the render options open it
/// wants most of a screen. As a sheet that meant either a clipped, scrolling
/// form or a queue window whose minimum size was dictated by its own modal —
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
          outputs
          if model.showsTrimOptions { trim }
          if model.isRenderingChat { RenderOptionsView(options: $model.renderOptions) }
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
      // What this job will actually write, so the name field is not a guess.
      Text(exampleFilenames)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var outputs: some View {
    Section("Download") {
      Toggle(isClip ? "Clip" : "Video", isOn: $model.isDownloadingMedia)
      // Directly under the toggle it qualifies, rather than in a row of its
      // own below every toggle: the quality is a property of the video
      // download, and nothing else on this sheet reads it.
      if model.isDownloadingMedia {
        Picker("Quality", selection: $model.quality) {
          Text("Best available").tag("")
          ForEach(model.qualities, id: \.name) { quality in
            Text(model.label(for: quality)).tag(quality.name)
          }
        }
      }

      Toggle("Chat", isOn: $model.isDownloadingChat)
      // Hidden under Render, which forces the download to JSON whatever the
      // picker says — see `IntakeModel.deliveredChatFormat`.
      if model.isDownloadingChat && !model.isRenderingChat {
        Picker("Chat format", selection: $model.chatFormat) {
          Text("JSON").tag(ChatFormat.json)
          Text("Text").tag(ChatFormat.text)
          Text("HTML").tag(ChatFormat.html)
        }
      }

      Toggle("Render chat", isOn: $model.isRenderingChat)
      if model.isRenderingChat && !model.isDownloadingChat {
        Text("The chat file is downloaded to render and then discarded.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var trim: some View {
    Section("Trim") {
      LabeledContent("Start") {
        TextField("Start", text: $model.trimStartText, prompt: Text("0:00"))
          .labelsHidden()
      }
      LabeledContent("End") {
        TextField("End", text: $model.trimEndText, prompt: Text("End of video"))
          .labelsHidden()
      }
      if model.trimIsInvalid {
        Label(
          "Use h:mm:ss, m:ss, or seconds. The end must come after the start.",
          systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
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
  private var footer: some View {
    VStack(spacing: 12) {
      destination
      buttons
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
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
      Button("Add") { add() }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canAdd || isAdding)
    }
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
  private var exampleFilenames: String {
    var names: [String] = []
    if model.isDownloadingMedia { names.append(model.outputBaseName + OutputSuffix.video) }
    if model.isDownloadingChat {
      names.append(model.outputBaseName + OutputSuffix.chat(model.deliveredChatFormat))
    }
    if model.isRenderingChat { names.append(model.outputBaseName + OutputSuffix.render) }
    return names.isEmpty ? "No outputs selected." : names.joined(separator: "\n")
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
  folder: URL? = URL(filePath: "/Users/you/Downloads"))
  -> IntakeModel
{
  let model = IntakeModel(
    fetchInfo: { _ in
      guard let info else { throw VideoInfoFetchError.unparseableOutput(snippet: "") }
      return info
    },
    enqueue: { _, _ in })
  model.linkText = link
  model.folder = folder
  return model
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

#Preview("Video") {
  IntakeWindow(model: previewModel())
}

#Preview("Chat + render") {
  let model = previewModel()
  model.isDownloadingChat = true
  model.isRenderingChat = true
  return IntakeWindow(model: model)
}

#Preview("Empty") {
  IntakeWindow(model: previewModel(link: "", info: nil, folder: nil))
}

#Preview("Metadata failed") {
  IntakeWindow(model: previewModel(info: nil))
}
