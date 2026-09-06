import AppKit
import SwiftUI
import OxbowKit

/// Look up a channel, see what it has, choose a scope and settings, and add
/// the watch. Every rule this window obeys lives in `AddChannelModel`; this
/// is the rendering of it.
///
/// **`IntakeWindow`'s sibling, not its rewrite.** A channel add is the same
/// shape as a video add — a lookup, a settled result, some choices, an Add
/// that stays disabled until they compose into something real, a refusal
/// that stays on screen rather than dismissing — so this follows that
/// window's reasoning rather than inventing a second one. See
/// `AddChannelModel`'s own doc comment for why the model itself is smaller
/// than `IntakeModel`, and `docs/design/channel-watching.md` §3 for the
/// feature this is the UI half of.
///
/// **A window, not a sheet**, for the identical reason `IntakeWindow` gives:
/// the priced backfill line at the foot of this form (§3.3) is one more row a
/// sheet capped by the queue window's height would have to fight for space
/// against, and a window sizes itself instead. `Window` rather than
/// `WindowGroup` in `OxbowApp`, so the toolbar button re-focuses the one that
/// exists rather than stacking a second lookup on top of the first.
struct AddChannelWindow: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: AddChannelModel
  @State private var hostWindow: NSWindow?
  @State private var isAdding = false
  @FocusState private var isLoginFocused: Bool

  /// Reads free space directly against `model.folder`, the same way
  /// `destination` below reads the folder's Finder icon directly rather than
  /// going through the model — this is display only, never a gate on `Add`
  /// (§3.3 prices the choice, it does not block it). Injectable so a preview
  /// can pin a volume instead of reading the developer's own disk: see
  /// `previewModel`'s own comment on why `IntakeWindow`'s previews do the
  /// same for `VolumeSpace`.
  private let volumeSpace: VolumeSpace

  /// Runs once this window closes, after `model.reset()`.
  ///
  /// **This is the other half of fixing the Watching pane's stale-until-next-
  /// sweep bug.** `AddChannelModel` writes `watches.json` through its own
  /// `WatchStore`, a different instance from the one `WatchingModel` reads
  /// through — so a successful Add here is invisible to that model until
  /// something tells it to look again. `OxbowApp` hands in
  /// `{ watching?.refresh() }`; defaulting to a no-op keeps every preview and
  /// test below from having to supply one.
  private let onClose: () -> Void

  /// A watch waiting to be edited, from `OxbowApp`'s own `@State`.
  ///
  /// **A binding, not a plain value, so this window can clear it — the
  /// identical shape `IntakeWindow.pendingIntake` uses for the identical
  /// reason.** `AddChannelWindow` is a `Window`, not a `WindowGroup`, so
  /// `OxbowApp` holds the one instance of this scene's worth of state across
  /// opens and closes. A watch left set here after being consumed would
  /// resurrect Edit mode on the very next ordinary Add Channel open — the
  /// same staleness bug `IntakeWindow`'s own comment on `pendingIntake`
  /// describes, just for this window's Add/Edit split instead of that one's
  /// finding hand-off.
  @Binding private var pendingEdit: Watch?

  init(
    store: WatchStore, preferences: Preferences, volumeSpace: VolumeSpace = .live,
    pendingEdit: Binding<Watch?> = .constant(nil),
    onClose: @escaping () -> Void = {}
  ) {
    let feed = Self.liveChannelFeed
    _model = State(initialValue: AddChannelModel(
      store: store, preferences: preferences,
      fetch: { login in await Self.result { try await feed.archives(forLogin: login) } },
      fetchDisplayName: { login in await Self.result { try await feed.displayName(forLogin: login) } }))
    self.volumeSpace = volumeSpace
    _pendingEdit = pendingEdit
    self.onClose = onClose
  }

  /// For previews, and for anything else that wants to drive the window
  /// without a network behind it — `AddChannelModel`'s own init takes
  /// closures for exactly this reason, and this is what lets a preview reach
  /// them, the same role `IntakeWindow.init(model:)` plays for intake.
  ///
  /// `pendingEdit` defaults to a constant `nil`: no preview below exercises
  /// the Watching hand-off, so none of them need a real binding to clear —
  /// the previews that show editing mode call `model.beginEditing(_:)`
  /// directly instead, the same way `IntakeWindow`'s own previews apply a
  /// `PendingIntake` straight to the model rather than through a binding.
  init(
    model: AddChannelModel, volumeSpace: VolumeSpace = .live,
    pendingEdit: Binding<Watch?> = .constant(nil),
    onClose: @escaping () -> Void = {}
  ) {
    _model = State(initialValue: model)
    self.volumeSpace = volumeSpace
    _pendingEdit = pendingEdit
    self.onClose = onClose
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        channel

        // Editing shows the four settings with no scope choice above them
        // (requirement 3) and no priced backfill below them (requirement 5)
        // — `settings` itself already withholds the estimate on its own,
        // since `model.estimate` is nil while editing (no lookup ever runs),
        // but `scope` has no such self-gate and must not be reachable at all.
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
    // Dynamic, not the scene's own static "Add Channel" title — requirement
    // 6. `JobInfoWindow.navigationTitle` is the precedent for overriding a
    // `Window` scene's title from inside its content this way.
    .navigationTitle(model.isEditing ? "Edit Channel" : "Add Channel")
    // A pending edit wins over the standing preferences: someone who chose
    // Edit on a specific channel did not mean to see today's global
    // defaults. Checked first, and `reseedFromPreferences()` runs only in
    // the branch that does not consume one — `beginEditing(_:)` seeds
    // everything editing needs on its own, from the watch, and re-seeding
    // from `Preferences` afterwards would immediately undo the freeze this
    // whole window exists to respect (§3.2).
    .onAppear {
      if let pendingEdit {
        model.beginEditing(pendingEdit)
        self.pendingEdit = nil
      } else {
        // Re-reads the four standing preferences before anything else runs,
        // so a Settings change made while this window was closed is on
        // screen the moment it reopens — see
        // `AddChannelModel.reseedFromPreferences()`, and `IntakeWindow`'s
        // identical `.onAppear` call for the reasoning this mirrors.
        model.reseedFromPreferences()
      }
    }
    // Catches an edit request that arrives while this window is already
    // open. `Window`'s single-instance guarantee means `openWindow` just
    // refocuses an open window rather than recreating it, so `.onAppear`
    // above never fires a second time — without this, choosing Edit… on a
    // watched channel while the window was already open (in Add mode, or
    // editing a different channel) did nothing visible, and left
    // `pendingEdit` set for the *next* ordinary Add Channel open to
    // stumble into, locking it into Edit mode for a channel nobody asked
    // about this time. Unlike `QueueView`'s identical hazard for
    // `pendingIntake` — accepted there because its worst case is a delayed
    // prefill — this one puts the wrong mode on screen outright, so it gets
    // fixed rather than documented away.
    .onChange(of: pendingEdit) { _, newValue in
      guard let newValue else { return }
      model.beginEditing(newValue)
      pendingEdit = nil
    }
    // The scene outlives the window, so closing it has to do what dismissing
    // a sheet would have done for free. See `AddChannelModel.reset()` — and,
    // for the open half of the same problem, `reseedFromPreferences()`
    // above. Without this, reopening after a successful add shows that
    // channel's form again, fully composed, with Add still the default
    // action — one stray ⏎ then replaces that channel's watch with `seen`
    // recomputed from the stale lookup, discarding every finding the user
    // had already acted on.
    .onDisappear {
      model.reset()
      onClose()
    }
  }

  // MARK: - Sections

  /// The login, and what came back for it — or, while editing, the login
  /// alone, fixed.
  ///
  /// **Editing shows the login but never lets it be typed** (requirement 2).
  /// Changing which channel a watch points at is not an edit, it is a
  /// different watch with a different `seen` set — `WatchingModel
  /// .stopWatching(_:)` and `Section.id` both key on the login as a stable
  /// identity, and a text field here would invite treating it as just
  /// another setting. There is also nothing to look up: `AddChannelModel
  /// .beginEditing(_:)` runs no fetch, so the Look Up button and everything
  /// below it that only makes sense once a lookup has settled — the
  /// unrecognised-login warning, the archive summary, a failure message —
  /// would all be reading state that can never become anything but idle.
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
          // A deliberate action rather than intake's debounced `.task(id:)`.
          // A pasted link is unambiguously finished the moment it lands; a
          // login is typed a character at a time and there is no clipboard
          // signal telling this window someone is done. Rather than guess
          // with a timer, `look()` runs only when asked — by this button,
          // or ⏎.
          Button("Look Up") { Task { await model.look() } }
            .disabled(model.normalisedLogin == nil || model.displayedLookup == .loading)
        }

        if model.isLoginUnrecognised {
          Label("That does not look like a Twitch channel.", systemImage: "xmark.circle")
            .font(.callout)
            .foregroundStyle(.red)
        } else {
          // `displayedLookup`, not `lookup` — a settled result for a login
          // that has since been edited away must read as `.idle`, not show
          // the previous channel's summary under the current one's text
          // field. See `AddChannelModel.displayedLookup`'s own doc comment.
          switch model.displayedLookup {
          case .idle:
            EmptyView()
          case .loading:
            ProgressView()
              .controlSize(.small)
          case .loaded(let archives):
            lookupSummary(archives)
          case .failed(let message):
            // Red, matching `isLoginUnrecognised` above rather than
            // intake's orange `metadataFailure`: intake's failure still
            // leaves a job composable from the id-derived fallback name,
            // but `AddChannelModel.composeWatch()` has nothing to fall back
            // to without archives in hand — this is a full stop, not a
            // degraded-but-workable state.
            Label(message, systemImage: "exclamationmark.triangle")
              .font(.callout)
              .foregroundStyle(.red)
          }
        }
      }
    }
  }

  /// The channel and what it has, once a lookup has settled.
  ///
  /// **Shows the login, not the display name.** `AddChannelModel` only
  /// resolves the real Twitch display name in `add()`, immediately before it
  /// is persisted (see `resolvedDisplayName(for:)`'s own doc comment for
  /// why) — paying for that round trip here, on every lookup, would be a
  /// second network call for a cosmetic difference the Watching sidebar shows
  /// a moment later anyway, once the watch exists.
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

  /// Only new, or all available — `docs/design/channel-watching.md` §3.1:
  /// neither is right often enough to be assumed, so it is a choice rather
  /// than a default silently applied.
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
        // §3.1: pagination is unreachable, so "all" is worded as exactly
        // what it delivers — never the unqualified promise a person would
        // otherwise read it as, on precisely the prolific channel where the
        // gap between "all" and "the newest 100" is likely to matter.
        Text("Every video shown above becomes a finding. Twitch will not "
          + "return more than its newest 100 archives, and Oxbow cannot "
          + "page past that limit.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// The four settings, seeded from `Preferences` when this window opened and
  /// frozen onto the watch by `AddChannelModel.add()` — never re-read from
  /// here, and never written back to `Preferences` either. `saveNote` below
  /// is what makes that one-way trip legible: unlike `IntakeWindow`, there is
  /// no checkbox offering to save these back as the new defaults, because a
  /// channel's settings and the app's standing defaults are two different
  /// things the moment this window closes (§3.2).
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

      // Checkbox, not a switch, matching `IntakeWindow`'s own reasoning for
      // "Make these settings my defaults": this reads as a persistent mode
      // once ticked, but the mode it sets is real and standing, so a switch
      // would say the same thing — the difference from intake's checkbox is
      // only that this one is not a one-shot action, it is the setting
      // itself.
      HStack {
        Toggle(isOn: $model.downloadsAutomatically) {
          Text("Download automatically")
        }
        .toggleStyle(.checkbox)
        Spacer(minLength: 0)
      }
      // Matches `WatchingView`'s tooltip on this same flag, worded for the
      // moment someone decides whether to tick this rather than for a
      // watch already ticked — same honesty, different point in the flow.
      // This used to say Oxbow didn't do this yet, on or off; automatic
      // downloading is real now, so what it says has to actually depend on
      // the checkbox above it rather than being true regardless of it.
      Text(model.downloadsAutomatically
        ? "New archives from this channel are queued and downloaded on "
          + "their own. A destination that's low on space or unavailable "
          + "pauses this channel until that clears — Watching will say so."
        : "New archives only appear in Watching until you press Add on a "
          + "finding.")
        .font(.caption)
        .foregroundStyle(.secondary)

      // Gated on `count > 0`, not just on `estimate` existing: `.onlyNew`
      // always prices an empty set (`AddChannelModel.estimate`'s own doc
      // comment), so `estimate` is non-nil the moment a lookup settles but
      // reads "about Zero KB" under that scope — a number with nothing
      // behind it. `scope`'s own caption above already says why nothing is
      // being fetched; this line only has something to add once `.allAvailable`
      // gives it a real backfill to price.
      if let estimate = model.estimate, estimate.count > 0 {
        if model.output == .videoWithChat {
          // `.help` carries the mechanism, not the caption itself — this is
          // the one control in the window that can move a number the
          // counter-intuitive way (turning chat *on* can shrink the figure;
          // see `backfillMechanismNote`), and a caption already carrying two
          // clauses ("about … at its peak · … free on …") has no room left
          // to defend itself against its own surprise.
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

  /// What copies onto the watch says, and why. Always ends the same way —
  /// this is a one-time freeze, not a promise that nothing here can ever be
  /// changed again.
  ///
  /// **A different note while editing**, because the add-mode wording is
  /// wrong there in a way that matters: "these settings start from your
  /// defaults" is false the moment they were seeded by `beginEditing(_:)`
  /// from the watch instead, and pointing back at "the Watching list" to
  /// revisit them is circular when the Watching list's own context menu is
  /// how this form got opened in the first place.
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

  /// What running the backfill this scope and these settings describe would
  /// need, and what is free to hold it.
  ///
  /// **"About", not a figure.** `BackfillEstimate`'s own doc comment is
  /// explicit that it prices a nominal rendition for the cap, never a real
  /// video's — the channel feed carries no renditions to price against — so
  /// this must never read with the precision `IntakeModel`'s own per-job
  /// `spaceWarningText` earns from an actual `StreamQuality`. Worded exactly
  /// as it would be if `estimate.bytes` had a hundred siblings that all
  /// disagreed with it by a little.
  ///
  /// **"At its peak", not "in total".** `BackfillEstimate.bytes` is not what
  /// the backfill leaves behind once every job is done — that would be the
  /// sum of what each archive delivers. It is what the disk has to hold
  /// while the backfill is *running*: every archive already delivered, plus
  /// one job's own transient overhead — only one job runs at a time
  /// (`TeardownJournal` tears down each one's scratch before the next
  /// starts, per `BackfillEstimate`'s own doc comment), so only one
  /// transient ever coexists with the delivered sum. Wording this as a
  /// standing total would promise a number the backfill never actually sits
  /// at.
  ///
  /// **Does NOT rise whenever chat is turned on — above roughly five
  /// archives it falls, and this line has to be read that way.** An earlier
  /// version of this comment claimed the opposite ("turning chat on adds a
  /// render pass with a transient of its own, so the peak … rises with it"),
  /// which is only true for a short backfill. `h264_videotoolbox`'s constant
  /// quality mode re-encodes the composite to about 47% of Twitch's own
  /// source bitrate at 1080p (`SpaceEstimate.compositeBitsPerPixel` against
  /// `CompositeGeometry.pixelRate`; `docs/design/disk-preflight.md` §5 records
  /// the same property in absolute terms — 15 GB of composite against 23 GB
  /// of source for the same six-hour job), while a plain video download pays
  /// the full source bitrate for every archive it keeps. Chat's own
  /// transient render pass is real, but it is paid once per *running job*,
  /// not once per archive, so it is a fixed cost that a longer backfill
  /// dilutes rather than a per-archive one that compounds. Past a small
  /// handful of archives — near five, by the same arithmetic — the saving on
  /// every archive already delivered outweighs that one fixed cost, and
  /// `Σ composite + one transient` drops below `Σ source`. Below that count
  /// the line still reads higher with chat on; above it, lower.
  private func backfillCaption(for estimate: BackfillEstimate) -> String {
    let needed = "about " + Int64(estimate.bytes).formatted(.byteCount(style: .file))
    guard let folder = model.folder, let available = volumeSpace.availableBytes(folder) else {
      return "Running this backfill will need \(needed) at its peak."
    }
    let free = available.formatted(.byteCount(style: .file))
    let name = volumeSpace.volumeName(folder) ?? folder.lastPathComponent
    return "Running this backfill will need \(needed) at its peak · \(free) free on \(name)"
  }

  /// Why turning chat on can *shrink* `backfillCaption`'s figure instead of
  /// growing it — see that function's own doc comment for the arithmetic.
  /// This is the only control in the window that moves a number the
  /// counter-intuitive way, so it is the one that has to say why: toggling
  /// Video → Video + chat and watching the estimate drop, with nothing on
  /// screen attributing it to anything, reads as a broken estimator rather
  /// than as the correct answer.
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

  /// Just the buttons, pinned below the form — `IntakeWindow.footer`'s own
  /// reasoning applies unchanged: the one thing this window commits to
  /// should not be able to scroll out of view under a growing form.
  private var footer: some View {
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
      // Requirement 6: Edit rather than Add, while editing.
      Button(model.isEditing ? "Edit" : "Add") { add() }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canAdd || isAdding)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
  }

  // MARK: - Actions

  /// Dismisses only once the watch is on disk. `model.add()` awaits the save
  /// all the way in and reports whether it landed; a refusal leaves the
  /// window open with its reason on screen, the same contract
  /// `IntakeWindow.add()` keeps with `IntakeModel`.
  private func add() {
    isAdding = true
    Task {
      let didAdd = await model.add()
      isAdding = false
      if didAdd { dismiss() }
    }
  }

  /// An Open panel, not a Save panel — unlike `IntakeWindow.chooseFolder()`
  /// this is choosing where a whole channel's future downloads land, never a
  /// single file's name, so there is no filename to seed and no
  /// `allowedContentTypes` to restrict.
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

  /// Turns a `ChannelFeedError`-throwing call into the `Result` shape
  /// `AddChannelModel`'s two closures expect, folding in any other error —
  /// URLSession's own offline/DNS/TLS failures — as `.unreachable`, the same
  /// translation `WatchPoller.sweep`'s own closure makes for the identical
  /// reason: `.server(status: 0)` would blame Twitch for the user's wifi.
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

  /// An ephemeral session over `ChannelFeed`, mirroring
  /// `WatchPoller.live(supportDirectory:)`'s own construction exactly —
  /// same timeout, same refusal to wait for connectivity, same reasoning
  /// against a URL cache for a question whose whole point is "what is there
  /// right now." Not shared with that method: this window has no
  /// `supportDirectory` to build a `WatchStore` from (its caller already has
  /// one), so there is nothing to gain by routing through it, only a
  /// parameter it does not need.
  ///
  /// **A lazy `static let`, not a function called from `init`.** SwiftUI
  /// re-evaluates a view's `init` on every scene-body re-render, but
  /// `_model = State(initialValue:)` only ever keeps the first result — every
  /// later call built a configuration, a session and a `ChannelFeed` purely
  /// to throw them away unread. Nothing about this value is per-window: the
  /// configuration is fixed and the session carries no state that should
  /// differ between one `AddChannelWindow` and the next, so one shared,
  /// lazily-built instance for the process is strictly more correct than a
  /// fresh one nobody asked for.
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

/// A model wired to a canned fetch, so the previews below show the window's
/// settled states without a network call — the same role `IntakeWindow`'s own
/// `previewModel` plays there, and for the same reasons: a fresh
/// `InMemoryPreferenceStore` per call so no preview here writes the real
/// `studio.lofti.Oxbow` domain, and a fixed `WatchStore` over a scratch file
/// so Add in a live preview canvas cannot touch a real watch list.
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
    fetchDisplayName: { _ in .success(login) })
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
  /// A volume with a fixed amount of room, matching `IntakeWindow`'s own
  /// `previewFull` — a canvas that changes with the developer's disk is a
  /// canvas nobody can review.
  fileprivate static func previewFull(free: Int64) -> VolumeSpace {
    VolumeSpace(
      availableBytes: { _ in free },
      volumeRoot: { _ in URL(filePath: "/") },
      volumeName: { _ in "Macintosh HD" })
  }
}

/// Idle: a login typed but `Look Up` never pressed — the everyday starting
/// point, since unlike intake's pasted link this window never fetches on its
/// own (see `channel`'s own doc comment on why `Look Up` is a deliberate
/// action).
#Preview("Idle") {
  AddChannelWindow(
    model: previewModel(archives: nil),
    volumeSpace: .previewFull(free: 500_000_000_000))
}

/// A settled lookup with archives in hand — scope, settings and the priced
/// backfill line are all showing. `.task` stands in for pressing `Look Up`:
/// this window fetches only on that explicit action, so a preview has to
/// trigger the identical call rather than relying on anything firing on
/// appear.
#Preview("Loaded with archives") {
  let model = previewModel()
  return AddChannelWindow(model: model, volumeSpace: .previewFull(free: 500_000_000_000))
    .task { await model.look() }
}

/// `scope` switched to `.allAvailable`, so the backfill total is priced
/// against something other than zero — `.onlyNew`'s own estimate is always
/// nought, since nothing is taken under it (`AddChannelModel.estimate`'s own
/// doc comment). The scope is set only after the lookup settles, matching how
/// a person would actually reach this state.
#Preview("All available - priced") {
  let model = previewModel()
  return AddChannelWindow(model: model, volumeSpace: .previewFull(free: 500_000_000_000))
    .task {
      await model.look()
      model.scope = .allAvailable
    }
}

/// A channel Twitch does not recognise. Add stays disabled and the refusal
/// reads as a fact about the channel, not a broken window.
#Preview("Failed lookup") {
  let model = previewModel(failure: .noSuchChannel)
  return AddChannelWindow(model: model, volumeSpace: .previewFull(free: 500_000_000_000))
    .task { await model.look() }
}

/// Editing an existing watch — Task 3. No scope picker, no priced backfill,
/// a fixed login, and Edit rather than Add on the title and the confirm
/// button — every one of `AddChannelModel.beginEditing(_:)`'s consequences
/// visible in one canvas. `previewModel`'s own fetch is never called here:
/// editing runs no lookup, so this calls `beginEditing(_:)` directly on a
/// freshly built model instead of routing through it.
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
