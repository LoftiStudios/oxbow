import Foundation
import Observation
import OxbowKit

/// Add/edit watch state and validation with injected fetches. canAdd delegates to composition
/// so UI eligibility matches what can be saved.
@MainActor
@Observable
final class AddChannelModel {

  /// Distinguish lookup failure from a successful empty archive list.
  enum Lookup: Equatable {
    case idle
    case loading
    case loaded([ChannelArchive])
    case failed(String)
  }

  // MARK: - What the user types and picks

  var loginText = ""

  /// Creation-only scope; default to future archives without adding the current back catalogue.
  var scope: Watch.Scope = .onlyNew

  /// Automatic downloads require explicit opt-in for each new watch.
  var downloadsAutomatically = false

  var qualityCap: QualityCap
  var output: DownloadOutput
  var chatSize: ChatSize
  var folder: URL?

  private(set) var lookup: Lookup = .idle

  /// Identity of the settled lookup. A later login edit invalidates its use, even without
  /// starting another lookup.
  private(set) var lookupLogin: String?

  /// Generation orders fetches; this also checks whether the latest result still matches typed
  /// input.
  private var describesCurrentLogin: Bool {
    guard let lookupLogin, let normalisedLogin else { return false }
    return lookupLogin == normalisedLogin
  }

  /// All consumers use this identity-checked lookup; stale settled results appear idle.
  var displayedLookup: Lookup {
    switch lookup {
    case .idle, .loading: return lookup
    case .loaded, .failed: return describesCurrentLogin ? lookup : .idle
    }
  }

  /// Keep the window open with the reason when composition or persistence refuses Add.
  private(set) var addFailure: String?

  // MARK: - Editing an existing watch

  /// Retain the full watch while editing to preserve its identity, seen state, and display
  /// name. Clear on reset.
  private(set) var editingWatch: Watch?

  /// Editing fixes the login and omits creation-only scope and backfill controls.
  var isEditing: Bool { editingWatch != nil }

  /// Seed edits from the watch's frozen settings, not current preferences. Changing login would
  /// change watch identity and is not an edit.
  func beginEditing(_ watch: Watch) {
    editingWatch = watch
    loginText = watch.login
    qualityCap = watch.settings.qualityCap
    output = watch.settings.output
    chatSize = watch.settings.chatSize
    folder = watch.settings.destination
    downloadsAutomatically = watch.downloadsAutomatically
    // Clear lookup state left from an earlier Add session; editing performs no lookup.
    lookup = .idle
    lookupLogin = nil
    addFailure = nil
    generation += 1
  }

  // MARK: - Collaborators

  private let store: WatchStore

  /// Retain shared preferences to pick up Settings changes on each open.
  private let preferences: Preferences

  /// Accept only normalized logins; ChannelFeed interpolates them into GraphQL queries.
  private let fetch: (String) async -> Result<[ChannelArchive], ChannelFeedError>

  /// Fetch display name once on add, using the normalized login. Profile failure falls back to
  /// login without blocking persistence.
  private let fetchProfile: (String) async -> Result<ChannelProfile, ChannelFeedError>

  /// Reject superseded lookups so archives cannot seed the wrong channel.
  private var generation = 0

  /// Inject fetches for tests. New watches freeze current preferences on save; the retained
  /// window model re-reads preferences on each open.
  init(
    store: WatchStore,
    preferences: Preferences,
    fetch: @escaping (String) async -> Result<[ChannelArchive], ChannelFeedError>,
    fetchProfile: @escaping (String) async -> Result<ChannelProfile, ChannelFeedError>)
  {
    self.store = store
    self.preferences = preferences
    self.fetch = fetch
    self.fetchProfile = fetchProfile
    self.qualityCap = preferences.qualityCap
    self.output = preferences.output
    self.chatSize = preferences.chatSize
    self.folder = preferences.destination
  }

  // MARK: - Starting over

  /// Clear channel and lookup state on close, then reseed defaults. Reusing a stale loaded
  /// model could recreate a watch and discard its handled findings.
  func reset() {
    loginText = ""
    lookup = .idle
    lookupLogin = nil
    scope = .onlyNew
    downloadsAutomatically = false
    addFailure = nil
    editingWatch = nil
    reseedFromPreferences()
    // Invalidate in-flight lookups before resetting state.
    generation += 1
  }

  /// Reload defaults on every open to pick up Settings edits made while closed. Preserve
  /// current login and lookup state.
  func reseedFromPreferences() {
    qualityCap = preferences.qualityCap
    output = preferences.output
    chatSize = preferences.chatSize
    folder = preferences.destination
  }

  // MARK: - The login

  /// Normalize typed input once before any watch construction or fetch.
  var normalisedLogin: String? { Watch.normalisedLogin(loginText) }

  /// Non-empty invalid input is an error; a blank field is not.
  var isLoginUnrecognised: Bool {
    !loginText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && normalisedLogin == nil
  }

  /// Fetch normalized login archives outside the queue. Generation rejects superseded requests;
  /// lookupLogin also invalidates a settled result when text changes without another lookup.
  func look() async {
    guard let login = normalisedLogin else {
      lookup = .idle
      lookupLogin = nil
      return
    }

    generation += 1
    let issued = generation
    lookup = .loading
    switch await fetch(login) {
    case .success(let archives):
      guard issued == generation else { return }
      lookup = .loaded(archives)
      lookupLogin = login
    case .failure(let error):
      guard issued == generation else { return }
      lookup = .failed(error.localizedDescription)
      lookupLogin = login
    }
  }

  // MARK: - Pricing the backfill

  /// Price only settled current-login results. onlyNew takes nothing immediately; allAvailable
  /// prices the returned page.
  var estimate: BackfillEstimate? {
    guard case .loaded(let archives) = displayedLookup else { return nil }
    let taken: [ChannelArchive]
    switch scope {
    case .onlyNew: taken = []
    case .allAvailable: taken = archives
    }
    return BackfillEstimate(archives: taken, cap: qualityCap, output: output)
  }

  /// Show scope and settings only for a current successful lookup with archives.
  var hasArchivesToConfigure: Bool {
    if case .loaded(let archives) = displayedLookup { return !archives.isEmpty }
    return false
  }

  // MARK: - Composing the watch

  /// Derive eligibility from the active composition path: new watches need a lookup, edits use
  /// the existing watch.
  var canAdd: Bool {
    isEditing ? composeEditedWatch() != nil : composeWatch() != nil
  }

  /// Require a matching non-empty lookup before creating a watch so scope is based on this
  /// channel's archives.
  private func composeWatch() -> Watch? {
    guard
      let login = normalisedLogin,
      case .loaded(let archives) = displayedLookup,
      !archives.isEmpty,
      let folder
    else { return nil }

    let settings = Watch.Settings(
      destinationPath: folder.path, qualityCap: qualityCap,
      output: output, chatSize: chatSize)
    // Use login provisionally; add() resolves display name once before saving, not during
    // repeated canAdd evaluations.
    let watch = Watch(
      login: login, displayName: login, settings: settings,
      downloadsAutomatically: downloadsAutomatically, seen: [])
    // Seed through Watch so in-progress archives follow the same scope rule.
    return watch.seeded(withScope: scope, from: archives)
  }

  /// Edit only settings and automatic-download policy, preserving identity and display name.
  /// add() refreshes seen from disk before save because the editing snapshot may be stale.
  private func composeEditedWatch() -> Watch? {
    guard let editingWatch, let folder else { return nil }

    let settings = Watch.Settings(
      destinationPath: folder.path, qualityCap: qualityCap,
      output: output, chatSize: chatSize)
    return Watch(
      login: editingWatch.login, displayName: editingWatch.displayName,
      settings: settings, downloadsAutomatically: downloadsAutomatically,
      seen: editingWatch.seen)
  }

  /// The last persisted watch, used to queue backfill with the settings actually saved.
  private(set) var savedWatch: Watch?

  /// Avatar from the display-name lookup; reuse it without a second fetch.
  private var resolvedAvatarURL: URL?

  /// Queue only downloadable backfill when automatic downloading and allAvailable are selected.
  /// Otherwise archives remain findings.
  var backfillToQueue: [ChannelArchive] {
    guard downloadsAutomatically, scope == .allAvailable,
          case .loaded(let archives) = lookup
    else { return [] }
    return archives.filter { $0.isDownloadable }
  }

  /// Re-read immediately before marking queued ids seen; metadata awaits allow other watch
  /// writers to run.
  func markQueued(_ ids: [String]) {
    guard let savedWatch, !ids.isEmpty else { return }
    guard var watches = try? store.load() else { return }
    guard let index = watches.firstIndex(where: { $0.login == savedWatch.login }) else { return }
    watches[index] = watches[index].marking(ids)
    try? store.save(watches)
  }

  @discardableResult
  func add() async -> Bool {
    guard var watch = isEditing ? composeEditedWatch() : composeWatch() else {
      addFailure = """
        Oxbow could not build that watch. Check the login, the lookup, and \
        the destination folder.
        """
      return false
    }

    // Only Add fetches profile details. Await before loading the watch list, then
    // load-modify-save without suspension. Refuse unreadable lists rather than overwriting
    // unseen watches, and replace by login to preserve uniqueness.
    if !isEditing {
      watch.displayName = await resolvedDisplayName(for: watch.login)
      watch.avatarURL = resolvedAvatarURL
    }

    let existing: [Watch]
    do {
      existing = try store.load()
    } catch {
      addFailure = """
        Oxbow could not read the existing watch list, so \
        \(isEditing ? "saving this channel" : "adding this channel") was \
        refused rather than risk losing it. \(error.localizedDescription)
        """
      return false
    }

    // Refresh seen from disk so edits cannot undo sweep submissions or failure recovery. If the
    // watch was removed, retain the editing snapshot's seen state.
    if isEditing, let editingWatch {
      watch.seen = existing.first(where: { $0.login == editingWatch.login })?.seen ?? editingWatch.seen
    }

    var watches = existing
    if let index = watches.firstIndex(where: { $0.login == watch.login }) {
      watches[index] = watch
    } else {
      watches.append(watch)
    }

    do {
      try store.save(watches)
      addFailure = nil
      savedWatch = watch
      return true
    } catch {
      addFailure = "Oxbow could not save the watch list: \(error.localizedDescription)"
      return false
    }
  }

  /// Profile failure is cosmetic: fall back to login and no avatar without blocking Add.
  private func resolvedDisplayName(for login: String) async -> String {
    switch await fetchProfile(login) {
    case .success(let profile):
      resolvedAvatarURL = profile.avatarURL
      return profile.displayName
    case .failure:
      resolvedAvatarURL = nil
      return login
    }
  }
}
