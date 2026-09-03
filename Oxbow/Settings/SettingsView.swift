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

  /// `Preferences()` defaults to `UserDefaults.standard` — correct here,
  /// unlike the preview below: this is the real Settings window, reading and
  /// writing the user's actual saved defaults.
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
      Picker("Download", selection: outputBinding) {
        Text("Video + chat").tag(DownloadOutput.videoWithChat)
        Text("Video").tag(DownloadOutput.video)
      }

      // The five rungs, in the order `QualityCap.allCases` already declares
      // them (best to worst) — no re-sorting needed here.
      Picker("Quality", selection: qualityCapBinding) {
        ForEach(QualityCap.allCases, id: \.self) { cap in
          Text(cap.label).tag(cap)
        }
      }

      Picker("Chat text size", selection: chatSizeBinding) {
        Text("Small").tag(ChatSize.small)
        Text("Medium").tag(ChatSize.medium)
        Text("Large").tag(ChatSize.large)
      }

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
          // Reassigning the mirrors here writes nothing back to the store —
          // see `outputBinding` and its siblings below for why. If this were
          // still a plain `$output`-style binding backed by `.onChange`,
          // this reassignment would fire it and immediately re-set
          // `hasSavedDefaults` to true for every field that actually
          // changed, undoing everything this button exists to undo.
          //
          // Re-read every mirror from the store rather than hard-coding
          // factory values here, so this stays correct if the factory
          // values themselves ever change.
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

  // MARK: - Bindings that write through on a user's pick, and only then
  //
  // **Not `$output` plus `.onChange(of:)`.** That was the first version, and
  // it was wrong: `.onChange` fires on *any* change to the `@State` mirror,
  // including Restore Defaults reassigning it back from the now-cleared
  // store, and `Preferences`' setters all call `recordSave()`. So Restore
  // Defaults' own reassignment of a field the user had actually changed
  // would re-trigger `.onChange`, write that value straight back to the
  // store, and set `hasSavedDefaults` to true again — undoing the one flag
  // (§2.4) this window is supposed to be able to undo, silently, because
  // nothing reads that flag yet to surface the bug.
  //
  // An explicit `Binding` whose setter writes both halves — the same shape
  // `IntakeWindow.qualityBinding` already uses — draws exactly the
  // distinction that matters: a `Picker` selection calls this setter, a
  // plain `@State` reassignment from Restore Defaults does not.
  //
  // Binding straight through to `preferences` instead, with no mirror at
  // all, was also considered and does not work: `Preferences`'s setters
  // write `UserDefaults` without mutating the struct's own storage, so
  // `@State` observes no change and the view never redraws.
  private var outputBinding: Binding<DownloadOutput> {
    Binding(get: { output }, set: { output = $0; preferences.output = $0 })
  }

  private var qualityCapBinding: Binding<QualityCap> {
    Binding(get: { qualityCap }, set: { qualityCap = $0; preferences.qualityCap = $0 })
  }

  private var chatSizeBinding: Binding<ChatSize> {
    Binding(get: { chatSize }, set: { chatSize = $0; preferences.chatSize = $0 })
  }

  /// A sheet on this window, the normal path — never `runModal()` for the
  /// case where `hostWindow` is already known. `IntakeWindow.chooseFolder()`
  /// carries the comment explaining why: an app-modal panel appears detached
  /// from the window it belongs to and spins a nested runloop underneath
  /// SwiftUI. Same mechanism, reused rather than reinvented.
  ///
  /// **The nil-`hostWindow` fallback mirrors `IntakeWindow.chooseFolder()`
  /// exactly, for the same narrow race.** `HostWindowReader` assigns
  /// `hostWindow` via `DispatchQueue.main.async`, so there is a brief window
  /// after the view first appears where it is still nil; that cannot happen
  /// once the button below has actually been clicked; `runModal()` here is
  /// the same last-resort fallback `IntakeWindow` uses in that role, not a
  /// second competing mechanism — without it, a Choose… button pressed
  /// during that race would silently do nothing.
  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.directoryURL = destination

    guard let hostWindow else {
      if panel.runModal() == .OK, let url = panel.url {
        destination = url
        preferences.destination = url
      }
      return
    }
    panel.beginSheetModal(for: hostWindow) { response in
      guard response == .OK, let url = panel.url else { return }
      destination = url
      preferences.destination = url
    }
  }
}

// MARK: - Previews

#Preview("Settings") {
  // An in-memory store, never `.standard` — the same reasoning
  // `IntakeWindow`'s own `previewModel()` spells out at length: a canvas that
  // reads the developer's real saved defaults renders differently per
  // developer, and once this preview is interactive, clicking a picker in it
  // would write to the real `studio.lofti.Oxbow` domain. `UserDefaults(
  // suiteName:)` used to stand in for a scratch domain here, but a named
  // suite is still real `UserDefaults` — it persists a `.plist` to
  // `~/Library/Preferences` on first write, and that file outlives the
  // preview. `InMemoryPreferenceStore` gives the same isolation with nothing
  // to clean up afterward.
  SettingsView(
    preferences: Preferences(
      store: InMemoryPreferenceStore(),
      homeDirectory: URL(filePath: "/Users/preview"),
      directoryExists: { _ in true }))
}
