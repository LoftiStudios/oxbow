import AppKit
import SwiftUI
import OxbowKit

struct IntakeSheet: View {
  let controller: QueueController

  @Environment(\.dismiss) private var dismiss
  @State private var urlText = ""
  @State private var destination: URL?
  @State private var hostWindow: NSWindow?

  /// Live validation, so the destination's suggested name can use the id
  /// before anything is enqueued.
  ///
  /// Only `.video` is surfaced here — `TwitchLink.parse` also recognizes
  /// clips, but this sheet only ever builds a video `JobTemplate`, and is
  /// rewritten wholesale in Task 8 to wire clips (and the chat/render
  /// toggles) up properly. Until then, treating a parsed clip as "not a
  /// target" keeps Add honestly disabled instead of enqueueing nothing and
  /// closing as if it worked.
  private var target: TwitchLink.Target? {
    let parsed = TwitchLink.parse(urlText)
    guard case .video = parsed else { return nil }
    return parsed
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Add Download").font(.headline)

      VStack(alignment: .leading, spacing: 4) {
        TextField("Twitch VOD URL", text: $urlText)
          .textFieldStyle(.roundedBorder)
        if !urlText.isEmpty && target == nil {
          Text("That does not look like a Twitch VOD address.")
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      HStack {
        Text(destination?.lastPathComponent ?? "No destination chosen")
          .foregroundStyle(destination == nil ? .secondary : .primary)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        Button("Choose…") { chooseDestination() }
          .disabled(target == nil)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Add") { add() }
          .keyboardShortcut(.defaultAction)
          .disabled(target == nil || destination == nil)
      }
    }
    .padding(20)
    .frame(width: 440)
    .background(HostWindowReader(window: $hostWindow))
  }

  private func chooseDestination() {
    // `target` is only ever `.video` — see its doc comment — so this always
    // matches.
    guard case .video(let videoID) = target else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "twitch-\(videoID).mp4"
    panel.directoryURL = try? FileManager.default.url(
      for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    panel.canCreateDirectories = true

    // A sheet on the sheet. `runModal()` here would stack an app-modal panel
    // on top of a sheet — it appears detached from the window it belongs to,
    // and it spins a nested runloop underneath SwiftUI.
    guard let hostWindow else {
      // Only if the window has not been read back yet, which cannot happen
      // once the sheet is on screen and the user has clicked a button in it.
      if panel.runModal() == .OK { destination = panel.url }
      return
    }
    panel.beginSheetModal(for: hostWindow) { response in
      if response == .OK { destination = panel.url }
    }
  }

  /// `target` is only ever `.video` here — Add is disabled otherwise — so
  /// this always matches. One validation path, shown live as the user types.
  private func add() {
    guard case .video(let videoID) = target, let destination else { return }
    // An empty quality means best available - see ArgumentBuilder.
    let request = VideoRequest(videoID: videoID, quality: "", destination: destination)
    controller.enqueue(JobTemplate(media: .video(request)), title: "Video \(videoID)")
    dismiss()
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
