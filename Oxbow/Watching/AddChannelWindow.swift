import AppKit
import SwiftUI
import OxbowKit

/// Single add/edit channel window backed by AddChannelModel. Sizes independently of the queue;
/// see docs/design/channel-watching.md §3.
struct AddChannelWindow: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: AddChannelModel
  @State private var hostWindow: NSWindow?
  @State private var isAdding = false

  /// Why some of the backfill did not reach the queue, if any of it did not.
  /// Shown beside `model.addFailure`, which covers the watch itself.
  @State private var backfillFailure: String?
  @FocusState private var isLoginFocused: Bool

  /// Advisory capacity display, injected for deterministic previews; never gates Add.
  private let volumeSpace: VolumeSpace

  /// After close/reset, ask Watching to reload writes made through this window's store handle.
  private let onClose: () -> Void

  /// Poll after a successful save so findings appear immediately. Separate from onClose, which
  /// also runs on Cancel and should not trigger network work.
  private let onSaved: () -> Void

  /// Consume and clear pending edits so the next Add Channel open cannot inherit editing mode.
  @Binding private var pendingEdit: Watch?

  init(
    store: WatchStore, preferences: Preferences, volumeSpace: VolumeSpace = .live,
    pendingEdit: Binding<Watch?> = .constant(nil),
    onClose: @escaping () -> Void = {},
    onSaved: @escaping () -> Void = {}
  ) {
    let feed = Self.liveChannelFeed
    _model = State(initialValue: AddChannelModel(
      store: store, preferences: preferences,
      fetch: { login in await Self.result { try await feed.archives(forLogin: login) } },
      fetchProfile: { login in await Self.result { try await feed.profile(forLogin: login) } }))
    self.volumeSpace = volumeSpace
    _pendingEdit = pendingEdit
    self.onClose = onClose
    self.onSaved = onSaved
  }

  /// Injected model supports previews without network access; no pending edit by default.
  init(
    model: AddChannelModel, volumeSpace: VolumeSpace = .live,
    pendingEdit: Binding<Watch?> = .constant(nil),
    onClose: @escaping () -> Void = {},
    onSaved: @escaping () -> Void = {}
  ) {
    _model = State(initialValue: model)
    self.volumeSpace = volumeSpace
    _pendingEdit = pendingEdit
    self.onClose = onClose
    self.onSaved = onSaved
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        channel

        // Editing omits creation-only scope and backfill controls.
        if model.isEditing {
          settings
        } else if model.hasArchivesToConfigure {
          scope
          settings
        }
      }
      .formStyle(.grouped)

      Divider()
      footer
    }
    .frame(minWidth: 460, minHeight: 360)
    .background(HostWindowReader(window: $hostWindow))
    .defaultFocus($isLoginFocused, true)
    .navigationTitle(model.isEditing ? "Edit Channel" : "Add Channel")
    // Apply pending edits before defaults; reseeding afterwards would overwrite frozen watch
    // settings.
    .onAppear {
      if let pendingEdit {
        model.beginEditing(pendingEdit)
        self.pendingEdit = nil
      } else {
        model.reseedFromPreferences()
      }
    }
    // Consume edits arriving while already open; refocusing a Window does not call onAppear
    // again.
    .onChange(of: pendingEdit) { _, newValue in
      guard let newValue else { return }
      model.beginEditing(newValue)
      pendingEdit = nil
    }
    // Reset the retained model on close so a later Return cannot recreate a stale watch.
    .onDisappear {
      model.reset()
      onClose()
    }
  }

  // MARK: - Sections

  /// Editing fixes the channel identity and performs no lookup; only new watches show editable
  /// login and lookup state.
  @ViewBuilder
  private var channel: some View {
    Section {
      if model.isEditing {
        Text(model.loginText)
          .font(.headline)
      } else {
        HStack {
          TextField("Login", text: $model.loginText, prompt: Text("Twitch channel login or URL"))
            .focused($isLoginFocused)
            .onSubmit { Task { await model.look() } }
          // Fetch only on Look Up or Return, not on each typed login change.
          Button("Look Up") { Task { await model.look() } }
            .disabled(model.normalisedLogin == nil || model.displayedLookup == .loading)
        }

        if model.isLoginUnrecognised {
          Label("That does not look like a Twitch channel.", systemImage: "xmark.circle")
            .font(.callout)
            .foregroundStyle(.red)
        } else {
          // Use the identity-checked lookup so edited text cannot display another channel's
          // results.
          switch model.displayedLookup {
          case .idle:
            EmptyView()
          case .loading:
            ProgressView()
              .controlSize(.small)
          case .loaded(let archives):
            lookupSummary(archives)
          case .failed(let message):
            // Lookup failure blocks Add, unlike intake's usable video-only metadata fallback.
            Label(message, systemImage: "exclamationmark.triangle")
              .font(.callout)
              .foregroundStyle(.red)
          }
        }
      }
    }
  }

  /// Show login until add() resolves the display name; no extra profile request during lookup.
  private func lookupSummary(_ archives: [ChannelArchive]) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(model.normalisedLogin ?? "")
        .font(.headline)
      if archives.isEmpty {
        Text("Twitch has no archives for this channel yet.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        let total = archives.reduce(Duration.zero) { $0 + $1.duration }
        Text("\(archives.count) archives · \(total.formatted(.time(pattern: .hourMinute))) total")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// Offer creation scope explicitly; see docs/design/channel-watching.md §3.1.
  private var scope: some View {
    Section {
      Picker("Backfill", selection: $model.scope) {
        Text("Only new").tag(Watch.Scope.onlyNew)
        Text("All available").tag(Watch.Scope.allAvailable)
      }

      if model.scope == .onlyNew {
        Text("Everything Twitch has right now is marked seen. Only videos "
          + "published after this channel is added will ever appear.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        // Describe the returned page, not an unqualified full catalogue: pagination is
        // unavailable.
        Text("Every video shown above becomes a finding. Twitch will not "
          + "return more than its newest 100 archives, and Oxbow cannot "
          + "page past that limit.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// Freeze these settings on the watch without writing back global preferences.
  @ViewBuilder
  private var settings: some View {
    Section {
      Picker("Quality", selection: $model.qualityCap) {
        ForEach(QualityCap.allCases, id: \.self) { cap in
          Text(cap.label).tag(cap)
        }
      }

      Picker("Download", selection: $model.output) {
        Text("Video + chat").tag(DownloadOutput.videoWithChat)
        Text("Video").tag(DownloadOutput.video)
      }

      if model.output == .videoWithChat {
        Picker("Chat text size", selection: $model.chatSize) {
          Text("Small").tag(ChatSize.small)
          Text("Medium").tag(ChatSize.medium)
          Text("Large").tag(ChatSize.large)
        }
      }

      destination

      Text(saveNote)
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack {
        Toggle(isOn: $model.downloadsAutomatically) {
          Text("Download automatically")
        }
        .toggleStyle(.checkbox)
        Spacer(minLength: 0)
      }
      // For allAvailable, the caption must include existing backfill rather than promise only
      // future archives.
      Text(automaticDownloadCaption)
        .font(.caption)
        .foregroundStyle(.secondary)

      // Hide the empty onlyNew estimate.
      if let estimate = model.estimate, estimate.count > 0 {
        if model.output == .videoWithChat {
          // Keep the estimator explanation in help text; enabling chat can reduce the estimated
          // backfill peak.
          Text(backfillCaption(for: estimate))
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(backfillMechanismNote)
        } else {
          Text(backfillCaption(for: estimate))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Settings")
    }
  }

  /// Explain frozen settings differently for creation and editing, which seeds from the watch
  /// itself.
  private var saveNote: String {
    guard model.isEditing else {
      return "These settings start from your defaults, but adding this "
        + "channel copies them onto it — they become this channel's own, "
        + "and a later change in Settings will not reach it. The Watching "
        + "list will be where they can be revisited."
    }
    return "Saving replaces what this channel was frozen to. Videos "
      + "already marked seen stay that way — only what happens from here "
      + "on changes."
  }

  /// Describe automatic downloading for the selected scope. New allAvailable watches include
  /// immediate backfill; edits and onlyNew describe future findings.
  private var automaticDownloadCaption: String {
    guard model.downloadsAutomatically else {
      return "New archives only appear in Watching until you press Add on a finding."
    }
    let pausesNote = "A destination that's low on space or unavailable pauses this "
      + "channel until that clears — Watching will say so."
    guard !model.isEditing, model.scope == .allAvailable else {
      return "New archives from this channel are queued and downloaded on their own. "
        + pausesNote
    }
    return "Every archive shown above is queued and downloaded now, not just new ones "
      + "— and any archive published after today is queued the same way. " + pausesNote
  }

  private func backfillCaption(for estimate: BackfillEstimate) -> String {
    let needed = "about " + Int64(estimate.bytes).formatted(.byteCount(style: .file))
    guard let folder = model.folder, let available = volumeSpace.availableBytes(folder) else {
      return "Running this backfill will need \(needed) at its peak."
    }
    let free = available.formatted(.byteCount(style: .file))
    let name = volumeSpace.volumeName(folder) ?? folder.lastPathComponent
    return "Running this backfill will need \(needed) at its peak · \(free) free on \(name)"
  }

  /// Explain why estimated composite delivery savings can outweigh one running job's transient
  /// overhead and reduce the backfill peak.
  private var backfillMechanismNote: String {
    "The chat build is re-encoded rather than kept at Twitch's own bitrate, "
      + "so across several archives it usually lands smaller than video alone."
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

  /// Pin action buttons outside the scrolling form.
  private var footer: some View {
    HStack(spacing: 12) {
      if let backfillFailure {
        Label(backfillFailure, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
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
      Button(model.isEditing ? "Edit" : "Add") { add() }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canAdd || isAdding)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
  }

  // MARK: - Actions

  /// Keep the window open on save refusal; dismiss only after persistence succeeds.
  private func add() {
    isAdding = true
    Task {
      let didAdd = await model.add()
      guard didAdd else {
        isAdding = false
        return
      }

      // Queue backfill immediately while refusals still have a window to appear in.
      await queueBackfill()
      isAdding = false

      guard backfillFailure == nil else { return }
      onSaved()
      dismiss()
    }
  }

  /// Keep partial successes, mark them seen, and report archives that could not be queued.
  private func queueBackfill() async {
    backfillFailure = nil
    let archives = model.backfillToQueue
    guard !archives.isEmpty, let watch = model.savedWatch else { return }

    guard case .ready(let controller) = await QueueHost.shared.ready() else {
      backfillFailure = """
        \(watch.displayName) is being watched, but Oxbow's download engine is \
        not available, so nothing was queued. The archives are waiting in \
        Watching.
        """
      return
    }

    let result = await ArchiveSubmission.submit(archives, for: watch, into: controller)
    model.markQueued(result.queued.map(\.id))

    guard !result.failures.isEmpty else { return }
    // Report a failure count and one representative reason rather than repeated messages.
    let reason = result.failures.values.sorted().first ?? ""
    if result.queued.isEmpty {
      backfillFailure = "None of the \(archives.count) archives could be queued. \(reason)"
    } else {
      backfillFailure = """
        \(result.queued.count) of \(archives.count) archives were queued. The \
        rest were refused: \(reason)
        """
    }
  }

  /// Choose a directory for future downloads, not a filename.
  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.directoryURL = model.folder

    guard let hostWindow else {
      if panel.runModal() == .OK, let url = panel.url { model.folder = url }
      return
    }
    panel.beginSheetModal(for: hostWindow) { response in
      guard response == .OK, let url = panel.url else { return }
      model.folder = url
    }
  }

  // MARK: - Wiring the live feed

  /// Convert typed feed errors to Result; map transport failures to unreachable rather than a
  /// server error.
  private static func result<T>(
    _ body: () async throws -> T) async -> Result<T, ChannelFeedError>
  {
    do {
      return .success(try await body())
    } catch let error as ChannelFeedError {
      return .failure(error)
    } catch {
      return .failure(.unreachable(error.localizedDescription))
    }
  }

  /// Shared lazy ephemeral feed avoids rebuilding discarded sessions on SwiftUI init calls.
  /// Match the poller's timeout and no-cache policy.
  private static let liveChannelFeed: ChannelFeed = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.waitsForConnectivity = false
    let session = URLSession(configuration: configuration)
    return ChannelFeed(fetch: { request in
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw ChannelFeedError.malformedPayload(snippet: "")
      }
      return (data, http)
    })
  }()
}

// MARK: - Previews

/// Canned fetches, fresh in-memory preferences, and a scratch watch file isolate interactive
/// previews.
@MainActor
private func previewModel(
  login: String = "day9tv",
  archives: [ChannelArchive]? = [
    AddChannelWindowPreviewData.long, AddChannelWindowPreviewData.short,
  ],
  failure: ChannelFeedError? = nil)
  -> AddChannelModel
{
  var preferences = Preferences(
    store: InMemoryPreferenceStore(),
    homeDirectory: URL(filePath: "/Users/preview"),
    directoryExists: { _ in true })
  preferences.destination = URL(filePath: "/Users/preview/Downloads")

  let model = AddChannelModel(
    store: WatchStore(fileURL: URL(filePath: "/tmp/oxbow-preview-watches.json")),
    preferences: preferences,
    fetch: { _ in
      if let failure { return .failure(failure) }
      return .success(archives ?? [])
    },
    fetchProfile: { _ in .success(ChannelProfile(displayName: login, avatarURL: nil)) })
  model.loginText = login
  return model
}

private enum AddChannelWindowPreviewData {
  static let long = ChannelArchive(
    id: "1", title: "Indie horror night",
    duration: .seconds(3 * 3600 + 24 * 60),
    publishedAt: Date().addingTimeInterval(-2 * 86400),
    status: .recorded, thumbnailURL: nil)

  static let short = ChannelArchive(
    id: "2", title: "Quick patch notes chat",
    duration: .seconds(42 * 60),
    publishedAt: Date().addingTimeInterval(-9 * 86400),
    status: .recorded, thumbnailURL: nil)
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

#Preview("Idle") {
  AddChannelWindow(
    model: previewModel(archives: nil),
    volumeSpace: .previewFull(free: 500_000_000_000))
}

/// Trigger look() explicitly; the real window does not fetch on appearance.
#Preview("Loaded with archives") {
  let model = previewModel()
  return AddChannelWindow(model: model, volumeSpace: .previewFull(free: 500_000_000_000))
    .task { await model.look() }
}

/// Set allAvailable after lookup to show a non-empty backfill estimate.
#Preview("All available - priced") {
  let model = previewModel()
  return AddChannelWindow(model: model, volumeSpace: .previewFull(free: 500_000_000_000))
    .task {
      await model.look()
      model.scope = .allAvailable
    }
}

#Preview("Failed lookup") {
  let model = previewModel(failure: .noSuchChannel)
  return AddChannelWindow(model: model, volumeSpace: .previewFull(free: 500_000_000_000))
    .task { await model.look() }
}

/// Seed editing directly without a lookup; verify fixed login and absence of scope/backfill
/// controls.
#Preview("Editing") {
  let model = previewModel(login: "leighxp")
  model.beginEditing(Watch(
    login: "leighxp", displayName: "LeighXP",
    settings: .init(
      destinationPath: "/Users/preview/Movies/LeighXP", qualityCap: .p720,
      output: .videoWithChat, chatSize: .medium),
    downloadsAutomatically: true, seen: ["1", "2", "3"]))
  return AddChannelWindow(model: model, volumeSpace: .previewFull(free: 500_000_000_000))
}
