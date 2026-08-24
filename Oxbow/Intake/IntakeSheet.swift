import AppKit
import SwiftUI

struct IntakeSheet: View {
  let controller: QueueController

  @Environment(\.dismiss) private var dismiss
  @State private var urlText = ""
  @State private var destination: URL?
  @State private var hostWindow: NSWindow?

  /// Live validation, so the destination's suggested name can use the id
  /// before anything is enqueued.
  private var videoID: String? { TwitchVideoURL.videoID(from: urlText) }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Add Download").font(.headline)

      VStack(alignment: .leading, spacing: 4) {
        TextField("Twitch VOD URL", text: $urlText)
          .textFieldStyle(.roundedBorder)
        if !urlText.isEmpty && videoID == nil {
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
          .disabled(videoID == nil)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Add") { add() }
          .keyboardShortcut(.defaultAction)
          .disabled(videoID == nil || destination == nil)
      }
    }
    .padding(20)
    .frame(width: 440)
    .background(HostWindowReader(window: $hostWindow))
  }

  private func chooseDestination() {
    guard let videoID else { return }
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

  /// `videoID` is non-nil here — Add is disabled otherwise — so the parse
  /// inside `enqueueVideo` cannot fail, and the message the discarded `catch`
  /// used to set was a word-for-word copy of the inline one under the field.
  /// One validation path, shown live as the user types.
  private func add() {
    guard videoID != nil, let destination else { return }
    try? controller.enqueueVideo(urlText: urlText, destination: destination)
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
