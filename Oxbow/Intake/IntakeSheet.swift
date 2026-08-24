import AppKit
import SwiftUI

struct IntakeSheet: View {
  let controller: QueueController

  @Environment(\.dismiss) private var dismiss
  @State private var urlText = ""
  @State private var destination: URL?
  @State private var error: String?

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

      if let error {
        Text(error).font(.caption).foregroundStyle(.red)
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
  }

  private func chooseDestination() {
    guard let videoID else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "twitch-\(videoID).mp4"
    panel.directoryURL = try? FileManager.default.url(
      for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    panel.canCreateDirectories = true
    if panel.runModal() == .OK { destination = panel.url }
  }

  private func add() {
    guard let destination else { return }
    do {
      try controller.enqueueVideo(urlText: urlText, destination: destination)
      dismiss()
    } catch {
      self.error = "That does not look like a Twitch VOD address."
    }
  }
}
