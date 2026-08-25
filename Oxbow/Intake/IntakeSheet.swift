import AppKit
import SwiftUI
import OxbowKit

/// Paste a link, see what it is, choose which of its outputs you want, and
/// add the job. Every rule this sheet obeys lives in `IntakeModel`; this is
/// the rendering of it.
struct IntakeSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: IntakeModel
  @State private var hostWindow: NSWindow?
  @State private var isAdding = false

  init(controller: QueueController) {
    _model = State(initialValue: IntakeModel(controller: controller))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Add Download").font(.headline)

      link
      if model.hasSettledMetadata {
        Divider()
        naming
        outputs
        qualityPicker
        if model.showsTrimOptions { trim }
      }
      Divider()
      folderRow
      if let addFailure = model.addFailure {
        Text(addFailure).font(.caption).foregroundStyle(.red)
      }
      buttons
    }
    .padding(20)
    .frame(width: 460)
    .background(HostWindowReader(window: $hostWindow))
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

  private var link: some View {
    VStack(alignment: .leading, spacing: 4) {
      TextField("Twitch VOD or clip link", text: $model.linkText)
        .textFieldStyle(.roundedBorder)

      if model.isLinkUnrecognized {
        Text("That does not look like a Twitch VOD or clip address.")
          .font(.caption)
          .foregroundStyle(.red)
      } else if model.isLoadingMetadata {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Fetching video details…").font(.caption).foregroundStyle(.secondary)
        }
      } else if let failure = model.metadataFailure {
        // A failure, not a dead end: the name below has fallen back to the id
        // or slug and the sheet still works.
        Text(failure).font(.caption).foregroundStyle(.orange)
      } else if let info = model.info {
        Text("\(info.streamer) — \(info.title)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
  }

  private var naming: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Name").font(.caption).foregroundStyle(.secondary)
      TextField("Name", text: $model.name)
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
      Text(exampleFilenames).font(.caption).foregroundStyle(.secondary).lineLimit(3)
    }
  }

  private var outputs: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(isClip ? "Clip" : "Video", isOn: $model.isDownloadingMedia)

      HStack {
        Toggle("Chat", isOn: $model.isDownloadingChat)
        // Hidden under Render, which forces the download to JSON whatever the
        // picker says — see `IntakeModel.deliveredChatFormat`.
        if model.isDownloadingChat && !model.isRenderingChat {
          Picker("Format", selection: $model.chatFormat) {
            Text("JSON").tag(ChatFormat.json)
            Text("Text").tag(ChatFormat.text)
            Text("HTML").tag(ChatFormat.html)
          }
          .labelsHidden()
          .frame(width: 100)
        }
      }

      Toggle("Render chat", isOn: $model.isRenderingChat)
      if model.isRenderingChat {
        if !model.isDownloadingChat {
          Text("The chat file is downloaded to render and then discarded.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        ScrollView {
          RenderOptionsView(options: $model.renderOptions)
        }
        .frame(maxHeight: 260)
      }
    }
  }

  @ViewBuilder
  private var qualityPicker: some View {
    if model.isDownloadingMedia {
      Picker("Quality", selection: $model.quality) {
        Text("Best available").tag("")
        ForEach(model.qualities, id: \.name) { quality in
          Text(model.label(for: quality)).tag(quality.name)
        }
      }
    }
  }

  private var trim: some View {
    HStack(spacing: 8) {
      Text("Trim").frame(width: 60, alignment: .leading)
      TextField("Start", text: $model.trimStartText).textFieldStyle(.roundedBorder)
      Text("to")
      TextField("End", text: $model.trimEndText).textFieldStyle(.roundedBorder)
      if model.trimIsInvalid {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
          .help("Use h:mm:ss, m:ss, or seconds. The end must come after the start.")
      }
    }
  }

  private var folderRow: some View {
    HStack {
      Text(model.folder?.lastPathComponent ?? "No folder chosen")
        .foregroundStyle(model.folder == nil ? .secondary : .primary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      Button("Choose…") { chooseFolder() }
    }
  }

  private var buttons: some View {
    HStack {
      Spacer()
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
