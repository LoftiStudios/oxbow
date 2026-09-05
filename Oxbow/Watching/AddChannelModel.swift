import Foundation
import Observation
import OxbowKit

/// Everything the Add Channel sheet knows and every decision it makes.
///
/// **Small on purpose, next to `IntakeModel`.** The rules a channel add makes
/// are a strict subset of a single video's: one lookup instead of a fetch per
/// paste, a scope instead of a trim, and a `Watch` instead of a `JobTemplate`.
/// So this follows `IntakeModel`'s shape rather than inventing a new one —
/// collaborators injected as closures so a test needs no engine and no
/// network, a settled-state enum for the one asynchronous thing this does,
/// and `canAdd` defined as "the thing it would compose is non-nil" so the
/// button's enabled state and what Add can actually build cannot drift apart
/// (`docs/design/channel-watching.md` §3).
@MainActor
@Observable
final class AddChannelModel {

  /// Where the one lookup per typed login has got to.
  ///
  /// **`.failed` is not `.loaded([])`.** The two look the same to a naive
  /// reducer — both describe "nothing to show" — but they are not the same
  /// fact: one is Twitch saying this channel has no archives, the other is
  /// Oxbow never finding out. Collapsing them would show a broken lookup as a
  /// channel with nothing new, exactly the failure `WatchPollResult.Outcome`
  /// exists to prevent for a poll already in progress. Kept apart here for
  /// the same reason, before a `Watch` is even created.
  enum Lookup: Equatable {
    case idle
    case loading
    case loaded([ChannelArchive])
    case failed(String)
  }

  // MARK: - What the user types and picks

  var loginText = ""

  /// How the new watch's seen-set is seeded. Not a stored mode — see
  /// `Watch.Scope`'s own doc comment — only how `add()` seeds it once.
  /// `.onlyNew` by default: it is the cheaper of the two half the time it is
  /// wrong (design doc §3.1's own admission), and unlike `downloadsAutomatically`
  /// there is no floor argument for picking the safer side over the coin
  /// flip — but a default has to be something, and "nothing lands in the
  /// inbox the moment this channel is added" is the least surprising one.
  var scope: Watch.Scope = .onlyNew

  /// The checkbox that promotes this watch from *tell me* to *fetch it*.
  /// **Always false at seed** — design doc §2 and §11.1: the default has to
  /// be the state whose failure is survivable, and a channel that starts
  /// automatic teaches nobody to check what they are about to turn on.
  var downloadsAutomatically = false

  var qualityCap: QualityCap
  var output: DownloadOutput
  var chatSize: ChatSize
  var folder: URL?

  private(set) var lookup: Lookup = .idle

  /// Set when Add refused. Only reachable if `canAdd` and `composeWatch()`
  /// ever disagreed, which they cannot, or if the watch list could not be
  /// read back before saving over it (see `add()`) — but a sheet that closes
  /// on a watch that was never persisted is exactly the silent failure this
  /// whole path exists to avoid, so the refusal says so out loud instead of
  /// dismissing. The same idiom as `IntakeModel.addFailure`.
  private(set) var addFailure: String?

  // MARK: - Collaborators

  private let store: WatchStore

  /// Takes the *normalised* login, never `loginText` — see `look()`, the
  /// only call site. `ChannelFeed.archives(forLogin:)`'s own doc comment
  /// spells out why: the login is interpolated unescaped into a GraphQL
  /// query body, and this closure is the boundary that guarantees nothing
  /// unvalidated ever reaches it.
  private let fetch: (String) async -> Result<[ChannelArchive], ChannelFeedError>

  /// Resolves the channel's real display name, once, in `add()` — never in
  /// `look()` or `composeWatch()`, both of which run far more often than a
  /// channel is actually added (`composeWatch()` on every `canAdd`
  /// re-evaluation) and must not each pay for a second network round trip.
  /// Takes the normalised login for the same reason `fetch` does. A failure
  /// falls back to the login itself rather than blocking the add — see
  /// `resolvedDisplayName(for:)`.
  private let fetchDisplayName: (String) async -> Result<String, ChannelFeedError>

  /// Distinguishes the fetch in flight from one the user has already
  /// superseded by editing the login. Without it, a slower fetch for an
  /// earlier login can land after a faster one for the current login and
  /// populate the model with the wrong channel's archives — and `add()`
  /// would then compose a `Watch` for the current login seeded from another
  /// channel's archive list entirely. The same guard `IntakeModel
  /// .generation` keeps for its own fetch, and for the same reason.
  private var generation = 0

  /// Both fetch collaborators are closures rather than `WatchPoller`/
  /// `ChannelFeed` instances so a test can supply a canned answer without a
  /// network or a real support directory — `WatchStore` alone is concrete
  /// because it is already an injectable value type with no network of its
  /// own (`WatchStoreTests` tests it the same way, against a scratch file).
  ///
  /// **Settings seed from `preferences` here and are then this model's own**
  /// — design doc §3.2. Unlike `IntakeModel`, which re-reads `Preferences` on
  /// every open because a window has an open moment to re-read at, a watch
  /// fires months later with nobody present, so there is no later moment to
  /// reseed from and no `reseedFromPreferences()` here to call.
  init(
    store: WatchStore,
    preferences: Preferences,
    fetch: @escaping (String) async -> Result<[ChannelArchive], ChannelFeedError>,
    fetchDisplayName: @escaping (String) async -> Result<String, ChannelFeedError>)
  {
    self.store = store
    self.fetch = fetch
    self.fetchDisplayName = fetchDisplayName
    self.qualityCap = preferences.qualityCap
    self.output = preferences.output
    self.chatSize = preferences.chatSize
    self.folder = preferences.destination
  }

  // MARK: - The login

  /// `loginText` run through `Watch.normalisedLogin`, which is the only
  /// legal way to turn typed text into something a `Watch` or a fetch may
  /// use. Every other member below reads this, never `loginText` itself.
  var normalisedLogin: String? { Watch.normalisedLogin(loginText) }

  /// Something was typed and it did not normalise. An empty field is not an
  /// error, it is the starting state — the same posture `IntakeModel
  /// .isLinkUnrecognized` takes about a blank link field.
  var isLoginUnrecognised: Bool {
    !loginText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && normalisedLogin == nil
  }

  /// Looks up the normalised login's archives, outside the queue, and
  /// settles into `.loaded` or `.failed`.
  ///
  /// Refuses at the guard rather than after: an unnormalised `loginText`
  /// never reaches `fetch`, which is the whole safety property this type
  /// exists to hold (`Watch.normalisedLogin`'s own doc comment).
  ///
  /// Guarded by `generation`: a fetch superseded by a later edit to the
  /// login must not settle `lookup` after the one that replaced it has —
  /// otherwise the model, and any `Watch` `add()` composes from it, would
  /// describe whichever channel happened to answer last rather than the one
  /// currently typed.
  func look() async {
    guard let login = normalisedLogin else {
      lookup = .idle
      return
    }

    generation += 1
    let issued = generation
    lookup = .loading
    switch await fetch(login) {
    case .success(let archives):
      guard issued == generation else { return }
      lookup = .loaded(archives)
    case .failure(let error):
      guard issued == generation else { return }
      lookup = .failed(error.localizedDescription)
    }
  }

  // MARK: - Pricing the backfill

  /// What this scope would actually take, priced against the current
  /// quality cap and output — design doc §3.3.
  ///
  /// **`.onlyNew` prices an empty set, not the found set.** Nothing is taken
  /// *now* under that scope — everything currently listed is marked seen
  /// rather than queued — so pricing the found archives here would quote a
  /// cost this Add will not actually incur. `.allAvailable` prices exactly
  /// what `add()` is about to seed nothing against, which is the whole
  /// returned page.
  ///
  /// Nil before a lookup has settled with something to price: an estimate
  /// over a placeholder is fiction, the same gate `IntakeModel.spaceWarning`
  /// applies before metadata has settled.
  var estimate: BackfillEstimate? {
    guard case .loaded(let archives) = lookup else { return nil }
    let taken: [ChannelArchive]
    switch scope {
    case .onlyNew: taken = []
    case .allAvailable: taken = archives
    }
    return BackfillEstimate(archives: taken, cap: qualityCap, output: output)
  }

  // MARK: - Composing the watch

  /// Exactly the condition under which `composeWatch()` returns something —
  /// one definition, so the button's enabled state and what Add can actually
  /// build cannot drift apart (the same contract `IntakeModel.canAdd` keeps
  /// with `composedTemplate()`).
  var canAdd: Bool { composeWatch() != nil }

  /// The watch this sheet would add, or nil if it is not in a state to add
  /// one.
  ///
  /// **A lookup that found zero archives does not qualify**, even though it
  /// succeeded: a watch over a channel with nothing recorded is not wrong,
  /// but there is nothing here yet to show the user what they are agreeing
  /// to seed or skip, and §3.1's whole premise — a real choice between
  /// scopes — needs at least one archive to be a real choice about.
  private func composeWatch() -> Watch? {
    guard
      let login = normalisedLogin,
      case .loaded(let archives) = lookup,
      !archives.isEmpty,
      let folder
    else { return nil }

    let settings = Watch.Settings(
      destinationPath: folder.path, qualityCap: qualityCap,
      output: output, chatSize: chatSize)
    // `displayName` seeds with the normalised login as a placeholder, not
    // the real thing. `composeWatch()` is synchronous and runs on every
    // `canAdd` re-evaluation, so it cannot itself perform the network fetch
    // `ChannelFeed.displayName(forLogin:)` needs — that only happens once,
    // in `add()`, right before this watch is persisted, and only `add()`'s
    // copy of `displayName` is the one that gets saved. See
    // `resolvedDisplayName(for:)`.
    let watch = Watch(
      login: login, displayName: login, settings: settings,
      downloadsAutomatically: downloadsAutomatically, seen: [])
    // The seen-set is seeded by `Watch.seeded(withScope:from:)` itself,
    // never reimplemented here — see that method's own doc comment for why
    // it seeds from every listed archive, including one still recording.
    return watch.seeded(withScope: scope, from: archives)
  }

  /// Adds the watch, replacing any existing watch for the same login rather
  /// than duplicating it.
  ///
  /// **Replace, not append.** `WatchingModel.Section.id` is the login and
  /// `markSeen` finds a watch with `firstIndex(where: { $0.login == login })`
  /// — both assume at most one watch per login. A second entry for the same
  /// channel would not raise an error; it would silently split that
  /// channel's state across two records, one of which nothing above this
  /// ever looks at again.
  ///
  /// **Refuses rather than saves over an unreadable list.** `WatchStore
  /// .load()` throws only when the watch file exists but could not be read —
  /// every decode failure it can hit is already recovered internally by
  /// moving the file aside (`WatchStore.setAside()`). So a throw here means
  /// there are watches on disk this call could not see, and saving anyway —
  /// what `try? store.load() ?? []` used to do — would silently overwrite
  /// every one of them with a list of exactly one. `addFailure` carries why,
  /// the same idiom as `IntakeModel.addFailure`, so the sheet can show it
  /// rather than closing on a watch list that just lost every other channel.
  ///
  /// Returns whether it landed, the same contract `IntakeModel.add()` keeps
  /// with its own sheet, so the caller can decide whether to dismiss on a
  /// fact rather than a hope.
  @discardableResult
  func add() async -> Bool {
    guard var watch = composeWatch() else {
      addFailure = """
        Oxbow could not build that watch. Check the login, the lookup, and \
        the destination folder.
        """
      return false
    }

    let existing: [Watch]
    do {
      existing = try store.load()
    } catch {
      addFailure = """
        Oxbow could not read the existing watch list, so adding this \
        channel was refused rather than risk losing it. \
        \(error.localizedDescription)
        """
      return false
    }

    watch.displayName = await resolvedDisplayName(for: watch.login)

    var watches = existing
    if let index = watches.firstIndex(where: { $0.login == watch.login }) {
      watches[index] = watch
    } else {
      watches.append(watch)
    }

    do {
      try store.save(watches)
      addFailure = nil
      return true
    } catch {
      addFailure = "Oxbow could not save the watch list: \(error.localizedDescription)"
      return false
    }
  }

  /// Twitch's own display name for `login`, or the normalised login itself
  /// when the lookup fails.
  ///
  /// **A missing display name must not block adding a channel.** The name is
  /// cosmetic — the sidebar heading, nothing `WatchPoll` reads to decide
  /// what to download — so a network hiccup here is not a reason to refuse
  /// the whole add the way an unreadable watch list is.
  private func resolvedDisplayName(for login: String) async -> String {
    switch await fetchDisplayName(login) {
    case .success(let name): return name
    case .failure: return login
    }
  }
}
