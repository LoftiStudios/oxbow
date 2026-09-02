import AppKit
import SwiftUI
import OxbowKit

/// The four standing preferences, and the only way to see or change them
/// without starting a download.
///
/// Not a duplicate of the intake's Download Options panel — two views on one
/// store with different jobs (design doc §5). The panel captures a decision
/// already being made about the video in front of you; this is where you find
/// out what your defaults actually are, and the only place to undo them.
///
/// **Changes write immediately.** A Save button is not what a Mac preferences
/// window does, and an edit here is exactly what `Preferences.hasSavedDefaults`
/// means (§2.4) — the same flag the intake's checkbox sets.
struct SettingsView: View {
  /// Captured with the same `HostWindowReader` pattern `IntakeWindow` uses
  /// (see `Oxbow/Intake/IntakeWindow.swift`), so the folder panel below can be
  /// a sheet on this window instead of an app-modal `runModal()`. Reusing the
  /// mechanism rather than inventing a second one.
  @State private var hostWindow: NSWindow?

  /// The store itself. Kept as state — not read fresh on every access —
  /// because `Preferences` wraps a `UserDefaults` and every write here needs
  /// to land on the same instance the four `@State` mirrors below were seeded
  /// from, including in the preview's fixed suite.
  @State private var preferences: Preferences

  // One `@State` mirror per stored value, the same shape `IntakeModel` uses
  // for its own seeded fields. A `Picker` needs a binding it owns; routing
  // every read through `preferences` directly would mean re-reading
  // `UserDefaults` on every body evaluation, and — worse — `Preferences`'
  // getters apply fallback logic (a missing destination resolves to
  // `~/Downloads`) that a two-way binding straight into the store would fight
  // with the moment the picker tried to reflect a value back.
  @State private var destination: URL
  @State private var qualityCap: QualityCap
  @State private var output: DownloadOutput
  @State private var chatSize: ChatSize

  /// `Preferences()` defaults to `.standard` — correct here, unlike the
  /// preview below: this is the real Settings window, reading and writing the
  /// user's actual saved defaults.
  init(preferences: Preferences = Preferences()) {
    _preferences = State(initialValue: preferences)
    _destination = State(initialValue: preferences.destination)
    _qualityCap = State(initialValue: preferences.qualityCap)
    _output = State(initialValue: preferences.output)
    _chatSize = State(initialValue: preferences.chatSize)
  }

  var body: some View {
    Form {
      // The same two-option control the intake's Download Options panel
      // uses — deliberately not an "Include chat" toggle. The store holds
      // `DownloadOutput`, the intake renders exactly these two labels, and a
      // Settings window with a different vocabulary for the same preference
      // is the drift design §5 exists to prevent.
      Picker("Download", selection: $output) {
        Text("Video + chat").tag(DownloadOutput.videoWithChat)
        Text("Video").tag(DownloadOutput.video)
      }
      .onChange(of: output) { _, newValue in preferences.output = newValue }

      // The five rungs, in the order `QualityCap.allCases` already declares
      // them (best to worst) — no re-sorting needed here.
      Picker("Quality", selection: $qualityCap) {
        ForEach(QualityCap.allCases, id: \.self) { cap in
          Text(cap.label).tag(cap)
        }
      }
      .onChange(of: qualityCap) { _, newValue in preferences.qualityCap = newValue }

      Picker("Chat text size", selection: $chatSize) {
        Text("Small").tag(ChatSize.small)
        Text("Medium").tag(ChatSize.medium)
        Text("Large").tag(ChatSize.large)
      }
      .onChange(of: chatSize) { _, newValue in preferences.chatSize = newValue }

      LabeledContent("Save to") {
        HStack(spacing: 8) {
          // The real Finder icon for the real folder, matching the intake's
          // own destination row (`IntakeWindow.destination`) — one visual
          // vocabulary for "this is a folder" across both windows.
          Image(nsImage: NSWorkspace.shared.icon(forFile: destination.path(percentEncoded: false)))
            .resizable()
            .frame(width: 16, height: 16)
          Text(destination.lastPathComponent)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(destination.path(percentEncoded: false))
          Button("Choose…", action: chooseFolder)
        }
      }

      Section {
        Button("Restore Defaults") {
          preferences.restoreDefaults()
          // `restoreDefaults()` clears the store; re-read every mirror from
          // it rather than hard-coding factory values here, so this stays
          // correct if the factory values themselves ever change.
          destination = preferences.destination
          qualityCap = preferences.qualityCap
          output = preferences.output
          chatSize = preferences.chatSize
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 420)
    // A `Form` sizes to its content vertically once its width is fixed; this
    // is what keeps the window from opening at some arbitrary default height
    // — the same treatment `AboutView` gives its own fixed-width window.
    .fixedSize(horizontal: false, vertical: true)
    .background(HostWindowReader(window: $hostWindow))
  }

  /// A sheet on this window, never `runModal()`. `IntakeWindow.chooseFolder()`
  /// carries the comment explaining why: an app-modal panel appears detached
  /// from the window it belongs to and spins a nested runloop underneath
  /// SwiftUI. Same mechanism, reused rather than reinvented.
  private func chooseFolder() {
    guard let hostWindow else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.directoryURL = destination
    panel.beginSheetModal(for: hostWindow) { response in
      guard response == .OK, let url = panel.url else { return }
      destination = url
      preferences.destination = url
    }
  }
}

// MARK: - Previews

#Preview("Settings") {
  // A fixed suite, never `.standard` — the same reasoning `IntakeWindow`'s
  // own `previewModel()` spells out at length: a canvas that reads the
  // developer's real saved defaults renders differently per developer, and
  // once this preview is interactive, clicking a picker in it would write to
  // the real `studio.lofti.Oxbow` domain. `UserDefaults(suiteName:)` gives a
  // scratch domain nothing else touches.
  SettingsView(
    preferences: Preferences(
      defaults: UserDefaults(suiteName: "SettingsPreview")!,
      homeDirectory: URL(filePath: "/Users/preview"),
      directoryExists: { _ in true }))
}
