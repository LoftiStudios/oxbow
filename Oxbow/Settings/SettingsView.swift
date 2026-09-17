import AppKit
import SwiftUI
import OxbowKit

/// Edit standing preferences immediately, including the automatic-download floor. Shares the
/// intake's store; edits count as saved defaults.
struct SettingsView: View {
  @State private var hostWindow: NSWindow?

  /// Retain the same preference store used to seed the state mirrors.
  @State private var preferences: Preferences

  // State mirrors provide observable bindings without repeated UserDefaults reads or fallback
  // values feeding back into the store.
  @State private var destination: URL
  @State private var qualityCap: QualityCap
  @State private var output: DownloadOutput
  @State private var chatSize: ChatSize
  @State private var freeSpaceFloor: Int64

  init(preferences: Preferences = Preferences()) {
    _preferences = State(initialValue: preferences)
    _destination = State(initialValue: preferences.destination)
    _qualityCap = State(initialValue: preferences.qualityCap)
    _output = State(initialValue: preferences.output)
    _chatSize = State(initialValue: preferences.chatSize)
    _freeSpaceFloor = State(initialValue: preferences.freeSpaceFloor)
  }

  var body: some View {
    Form {
      // Use the same DownloadOutput choices and labels as intake.
      Picker("Download", selection: outputBinding) {
        Text("Video + chat").tag(DownloadOutput.videoWithChat)
        Text("Video").tag(DownloadOutput.video)
      }

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

      // One global reserve with fixed byte-count choices; it is not a per-channel quota.
      Picker("Automatic download floor", selection: freeSpaceFloorBinding) {
        ForEach(FreeSpaceFloorRung.allCases, id: \.self) { rung in
          Text(rung.label).tag(rung.rawValue)
        }
      }
      // Explain that only automatic downloads pause; polling and inbox discovery continue.
      Text("""
        The point below which Oxbow stops downloading a watched channel on \
        its own. It keeps checking and listing what it finds either way — \
        only automatic downloading pauses, until there's more room.
        """)
        .font(.caption)
        .foregroundStyle(.secondary)

      Section {
        Button("Restore Defaults") {
          preferences.restoreDefaults()
          // Reload mirrors without setters after Restore Defaults so hasSavedDefaults remains
          // false.
          destination = preferences.destination
          qualityCap = preferences.qualityCap
          output = preferences.output
          chatSize = preferences.chatSize
          freeSpaceFloor = preferences.freeSpaceFloor
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 420)
    .fixedSize(horizontal: false, vertical: true)
    .background(HostWindowReader(window: $hostWindow))
  }

  // Explicit binding setters write both state and preferences only for user edits. onChange
  // would also save Restore Defaults' assignments; binding directly to Preferences would not
  // trigger a redraw.
  private var outputBinding: Binding<DownloadOutput> {
    Binding(get: { output }, set: { output = $0; preferences.output = $0 })
  }

  private var qualityCapBinding: Binding<QualityCap> {
    Binding(get: { qualityCap }, set: { qualityCap = $0; preferences.qualityCap = $0 })
  }

  private var chatSizeBinding: Binding<ChatSize> {
    Binding(get: { chatSize }, set: { chatSize = $0; preferences.chatSize = $0 })
  }

  private var freeSpaceFloorBinding: Binding<Int64> {
    Binding(get: { freeSpaceFloor }, set: { freeSpaceFloor = $0; preferences.freeSpaceFloor = $0 })
  }

  /// Attach the folder panel to the captured window. Use the modal fallback only before
  /// HostWindowReader has supplied a host.
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

// MARK: - The floor's rungs

/// Picker-only floor choices. Include Preferences.factoryFreeSpaceFloor so Restore Defaults
/// always has a selectable value; retain 49 GB for users of the old reserve.
private enum FreeSpaceFloorRung: Int64, CaseIterable {
  case factory = 10_000_000_000
  case twentyFive = 25_000_000_000
  case fortyNine = 49_000_000_000
  case oneHundred = 100_000_000_000
  case twoFifty = 250_000_000_000
  case fiveHundred = 500_000_000_000

  /// Use the same byte formatting as automatic-download explanations.
  var label: String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: rawValue)
  }
}

// MARK: - Previews

#Preview("Settings") {
  // Fresh in-memory preferences keep interactive previews deterministic and avoid persistent
  // files or real settings writes.
  SettingsView(
    preferences: Preferences(
      store: InMemoryPreferenceStore(),
      homeDirectory: URL(filePath: "/Users/preview"),
      directoryExists: { _ in true }))
}
