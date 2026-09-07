import Foundation
import Observation
import OxbowKit

/// Everything the Add Channel window knows and every decision it makes.
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

  /// The login the settled `lookup` actually describes.
  ///
  /// The login field is free text, editable at any moment, while `lookup`
  /// only ever changes when `look()` is asked to run it — pressing Look Up,
  /// or ⏎, not every keystroke. So the two can disagree: type `day9tv`, look
  /// it up, then edit the field to `ninja` without looking up again. Nothing
  /// about `canAdd` catches that on its own — it only checks that a login
  /// normalises and that *some* lookup has loaded — so without this,
  /// `composeWatch()` would build a watch for `ninja` seeded from `day9tv`'s
  /// archives. The exact drift `IntakeModel.metadataIdentifier`'s own doc
  /// comment describes: "everything derived from it … has to stop trusting
  /// it the moment the two disagree, or a job gets composed for one video
  /// out of another's details." Set only when `lookup` settles
  /// (`.loaded`/`.failed`), never for `.idle`/`.loading` — those need no
  /// identity check, since `look()` only ever enters `.loading` for the
  /// login it was just asked to run.
  private(set) var lookupLogin: String?

  /// Whether the settled `lookup` is this login's, rather than one it
  /// replaced. `generation` alone does not answer this: it only orders two
  /// concurrent fetches against each other, it says nothing about whether
  /// the *result that won* still describes what is currently typed.
  private var describesCurrentLogin: Bool {
    guard let lookupLogin, let normalisedLogin else { return false }
    return lookupLogin == normalisedLogin
  }

  /// `lookup`, but a settled `.loaded`/`.failed` that no longer describes
  /// `normalisedLogin` reads back as `.idle` instead.
  ///
  /// **Every reader of `lookup` outside `look()` itself goes through this,
  /// never the stored property directly** — `estimate`, `composeWatch()`,
  /// and everything `AddChannelWindow` renders from a settled state
  /// (`hasArchivesToConfigure`, the lookup summary). One gate, so none of
  /// them can drift out of step with each other the way `canAdd` and
  /// `composeWatch()` are already kept from drifting.
  var displayedLookup: Lookup {
    switch lookup {
    case .idle, .loading: return lookup
    case .loaded, .failed: return describesCurrentLogin ? lookup : .idle
    }
  }

  /// Set when Add refused. Only reachable if `canAdd` and `composeWatch()`
  /// ever disagreed, which they cannot, or if the watch list could not be
  /// read back before saving over it (see `add()`) — but a window that closes
  /// on a watch that was never persisted is exactly the silent failure this
  /// whole path exists to avoid, so the refusal says so out loud instead of
  /// dismissing. The same idiom as `IntakeModel.addFailure`.
  private(set) var addFailure: String?

  // MARK: - Editing an existing watch

  /// The watch this window is editing, or nil while it is composing a
  /// brand-new one.
  ///
  /// **Carries the whole original watch, not just its login.** Saving an
  /// edit has to hand back `seen` and `displayName` exactly as they already
  /// were — that is the entire point of this feature (`docs/design/
  /// channel-watching.md` §3.2's "offer an Edit", read together with §3.1's
  /// scope only ever applying once) — and both live only here, never
  /// reconstructed from the fields this window lets someone change. Set by
  /// `beginEditing(_:)`, cleared by `reset()` so a window that closes on an
  /// edit and reopens for Add does not stay stuck in editing mode.
  private(set) var editingWatch: Watch?

  /// Whether this window is editing `editingWatch` rather than composing a
  /// new watch. `AddChannelWindow` reads this to decide what to show: no
  /// scope picker (§3.1's scope only ever seeds a seen-set once, at
  /// creation), no backfill estimate (nothing is being taken), a fixed
  /// login, and Edit rather than Add on the title and the confirm button.
  var isEditing: Bool { editingWatch != nil }

  /// Switches this window into editing `watch`, seeding every field from the
  /// watch itself — never from `Preferences`, the way a brand-new channel
  /// does. That is the whole reason §3.2 offers an Edit at all: a watch set
  /// to 720p six weeks ago has to reopen showing 720p, whatever today's
  /// global default happens to be.
  ///
  /// The login is carried into `loginText` so the window can display it, but
  /// nothing here re-enables looking it up: `AddChannelWindow` renders it as
  /// fixed text while `isEditing` is true. Changing which channel a watch
  /// points at is not an edit, it is a different watch — a different `seen`
  /// set, and a different identity everything keying on `login`
  /// (`WatchingModel.Section.id`, `stopWatching(_:)`) assumes is stable.
  func beginEditing(_ watch: Watch) {
    editingWatch = watch
    loginText = watch.login
    qualityCap = watch.settings.qualityCap
    output = watch.settings.output
    chatSize = watch.settings.chatSize
    folder = watch.settings.destination
    downloadsAutomatically = watch.downloadsAutomatically
    // No lookup has run for this open, and none is coming — clears any
    // leftover state from a previous Add-mode session on this same
    // long-lived model, the identical concern `reset()` already handles for
    // the opposite direction.
    lookup = .idle
    lookupLogin = nil
    addFailure = nil
    generation += 1
  }

  // MARK: - Collaborators

  private let store: WatchStore

  /// Kept so `reseedFromPreferences()` has something to re-read from at each
  /// window open — see that method and `reset()`. Sharing the reference
  /// underneath this copy (`Preferences` holds its store as `AnyObject`, see
  /// that type's own doc comment) is exactly what makes a later Settings
  /// change visible here without this model needing to hear about it
  /// directly.
  private let preferences: Preferences

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
  /// **Settings seed from `preferences` here, and are then frozen onto the
  /// watch the moment `add()` persists it** — design doc §3.2. That freeze is
  /// about the saved `Watch`: it fires months later with nobody present, so
  /// nothing about a later Settings change can ever reach it, and it must
  /// not try. It says nothing about this *window*, which — like
  /// `IntakeWindow` — does have an open moment to re-read at. `Window`
  /// rather than `WindowGroup` (`AddChannelWindow`'s own doc comment) means
  /// this model, like `IntakeModel`, outlives one open/close cycle, so
  /// `reset()` and `reseedFromPreferences()` below exist for exactly the
  /// reason `IntakeModel`'s do.
  init(
    store: WatchStore,
    preferences: Preferences,
    fetch: @escaping (String) async -> Result<[ChannelArchive], ChannelFeedError>,
    fetchDisplayName: @escaping (String) async -> Result<String, ChannelFeedError>)
  {
    self.store = store
    self.preferences = preferences
    self.fetch = fetch
    self.fetchDisplayName = fetchDisplayName
    self.qualityCap = preferences.qualityCap
    self.output = preferences.output
    self.chatSize = preferences.chatSize
    self.folder = preferences.destination
  }

  // MARK: - Starting over

  /// Returns the window to its opening state, keeping what is a standing
  /// preference rather than this channel's business.
  ///
  /// **Why this has to exist at all.** `AddChannelWindow` is a `Window`, not
  /// a `WindowGroup` — one scene for the app's whole run, so a second ⌘N
  /// cannot stack a second lookup on top of the first — which means the
  /// model that survives a close is also the one the next open inherits.
  /// Without this, reopening the window after a successful add shows that
  /// same channel again: `loginText` still typed, `lookup` still `.loaded`,
  /// scope and the automatic-download checkbox still whatever they were left
  /// at — and Add is `.defaultAction`, enabled, sitting under the very key a
  /// person reaches for to dismiss the window they just finished with. One
  /// stray ⏎ then re-runs `add()`, which composes a fresh `Watch` from that
  /// stale `lookup` and replaces the existing one — under `.allAvailable`
  /// that watch's `seen` is `[]`, discarding every finding the user had
  /// already acted on for that channel. The same shape as `IntakeModel
  /// .reset()`'s own worst case, for the same reason: state that outlives a
  /// close and answers to a button that fires on ⏎.
  ///
  /// `folder`, `qualityCap`, `output` and `chatSize` come back from the
  /// preference store rather than surviving in place — see
  /// `reseedFromPreferences()`, which is what actually does that read.
  func reset() {
    loginText = ""
    lookup = .idle
    lookupLogin = nil
    scope = .onlyNew
    downloadsAutomatically = false
    addFailure = nil
    // Leaving this set would trap the next open in editing mode: `Window`
    // means this same model instance answers the very next open, whether
    // that is Edit on a different channel or the ordinary Add Channel
    // toolbar button — see `editingWatch`'s own doc comment.
    editingWatch = nil
    reseedFromPreferences()
    // Invalidates a fetch still in flight the same way a new login does, so
    // a late arrival cannot settle `lookup` into the window it just emptied.
    generation += 1
  }

  /// Re-reads the four standing preferences from the store, touching nothing
  /// about whatever channel is currently on screen.
  ///
  /// **Why `reset()` on close is not enough by itself.** `IntakeModel
  /// .reseedFromPreferences()`'s own doc comment spells out the general
  /// case: `reset()` only fires `.onDisappear`, once per *close*, which
  /// reseeds a window about to show a blank form for its next channel but
  /// does nothing for close this window, open Settings, change a default,
  /// close Settings, reopen this window — the reseed already happened at the
  /// first close, and nothing re-runs it before the second open.
  /// `AddChannelWindow` calls this from `.onAppear`, so every open re-reads
  /// the store regardless of whether anything changed since the last one.
  ///
  /// Deliberately narrower than `reset()`, for the same reason: an open can
  /// land on a window that already has a login typed or a lookup in flight,
  /// and clobbering that would be a second bug next to the one this fixes.
  func reseedFromPreferences() {
    qualityCap = preferences.qualityCap
    output = preferences.output
    chatSize = preferences.chatSize
    folder = preferences.destination
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
  ///
  /// **`generation` alone is not the whole guard.** It stops a *stale fetch*
  /// from landing late, but it does nothing about a *settled* `lookup` for
  /// login A sitting on screen after the field is edited to login B with no
  /// second lookup ever run — `generation` never advances, because nothing
  /// asked `look()` to run again. `lookupLogin`, set below, is what closes
  /// that second gap: see its own doc comment and `displayedLookup`.
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
  ///
  /// Reads `displayedLookup`, not `lookup` — a settled lookup for a login
  /// the field no longer holds must price nothing, the same reason
  /// `composeWatch()` below cannot build from it either.
  var estimate: BackfillEstimate? {
    guard case .loaded(let archives) = displayedLookup else { return nil }
    let taken: [ChannelArchive]
    switch scope {
    case .onlyNew: taken = []
    case .allAvailable: taken = archives
    }
    return BackfillEstimate(archives: taken, cap: qualityCap, output: output)
  }

  /// Whether a lookup settled with at least one archive to show scope and
  /// settings against — `AddChannelWindow`'s own gate for whether to render
  /// them at all.
  ///
  /// Reads `displayedLookup`, for the identical reason `estimate` does: a
  /// settled result for a login that has since been edited away must read
  /// as nothing to configure, not as the previous channel's archives.
  var hasArchivesToConfigure: Bool {
    if case .loaded(let archives) = displayedLookup { return !archives.isEmpty }
    return false
  }

  // MARK: - Composing the watch

  /// Exactly the condition under which `add()` would actually save something
  /// — one definition, so the button's enabled state and what Add (or, while
  /// `isEditing`, Edit) can actually build cannot drift apart (the same
  /// contract `IntakeModel.canAdd` keeps with `composedTemplate()`). Branches
  /// on `isEditing` because the two modes compose from entirely different
  /// sources — `composeWatch()` needs a settled, non-empty lookup;
  /// `composeEditedWatch()` needs none, since nothing about which archives
  /// exist changes what an edit saves.
  var canAdd: Bool {
    isEditing ? composeEditedWatch() != nil : composeWatch() != nil
  }

  /// The watch this window would add, or nil if it is not in a state to add
  /// one.
  ///
  /// **A lookup that found zero archives does not qualify**, even though it
  /// succeeded: a watch over a channel with nothing recorded is not wrong,
  /// but there is nothing here yet to show the user what they are agreeing
  /// to seed or skip, and §3.1's whole premise — a real choice between
  /// scopes — needs at least one archive to be a real choice about.
  ///
  /// **Reads `displayedLookup`, never `lookup` directly** — this is the one
  /// reader the whole `lookupLogin`/`displayedLookup` mechanism exists to
  /// protect: without it, looking up `day9tv` and then editing the field to
  /// `ninja` without looking up again leaves `lookup` sitting on `day9tv`'s
  /// archives while `login` below resolves to `ninja`, and this would
  /// compose a watch for `ninja` seeded from `day9tv`'s history. Under the
  /// default `.onlyNew` scope that marks `day9tv`'s ids seen on a `ninja`
  /// watch, leaving every one of `ninja`'s real archives unseen — the next
  /// sweep reports its entire back catalogue as new, the opposite of what
  /// the scope caption promises.
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

  /// The watch `add()` would save while `isEditing`, or nil if there is
  /// nothing yet to save one from.
  ///
  /// **Login, `displayName` and `seen` all come from `editingWatch`, never
  /// from anything editable in this window.** That is requirement 4 in full:
  /// an edit changes only what this window actually offers to change — the
  /// four settings and the automatic-download flag — and must not lose the
  /// one thing it never offers to change. Nothing here re-derives `seen`
  /// from a scope or a lookup the way `composeWatch()` does, because editing
  /// runs no lookup at all — there is no fresh archive list to seed against,
  /// only the watch's own history to carry forward untouched.
  ///
  /// **`seen` here is a starting point, not the final answer.** `add()`
  /// overwrites it again, right before saving, with whatever `existing`
  /// holds for this login at that moment — see that method's own doc
  /// comment for why `editingWatch.seen` alone is stale the instant a sweep
  /// or a failed download's un-mark lands during however long this window
  /// sits open before Edit is pressed. Kept here anyway, rather than left
  /// out, so `composeEditedWatch()` alone still returns something coherent
  /// for `canAdd` to gate on and for `add()` to fall back to if the login
  /// has since vanished from the store.
  ///
  /// Guarded on `folder` alone, the one field `Watch.Settings` cannot exist
  /// without — the login needs no guard, since it comes from `editingWatch`
  /// rather than from typed, possibly-unnormalised text.
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

  /// Adds or saves the watch, replacing any existing watch for the same
  /// login rather than duplicating it.
  ///
  /// **One method for both modes, not two.** Add and Edit differ only in
  /// what they compose from (`composeWatch()`'s fresh lookup versus
  /// `composeEditedWatch()`'s carried-forward `seen`) and whether the
  /// resolved display name is worth a network round trip for — everything
  /// after that, replace-not-duplicate and refuse-rather-than-overwrite
  /// alike, is one rule the two modes cannot be allowed to drift apart on.
  /// A second, hand-rolled `save()` next to this would be exactly the
  /// second place to keep the refusal rule correct that this feature's own
  /// brief warns against.
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
  /// every one of them with a list of exactly one. For an edit this is the
  /// identical bug in a different costume: it would not just fail to save
  /// the change, it would take every *other* watched channel down with it.
  /// `addFailure` carries why, the same idiom as `IntakeModel.addFailure`,
  /// so the window can show it rather than closing on a watch list that
  /// just lost every other channel.
  ///
  /// Returns whether it landed, the same contract `IntakeModel.add()` keeps
  /// with its own window, so the caller can decide whether to dismiss on a
  /// fact rather than a hope.
  ///
  /// **The display-name fetch happens before `store.load()`, not after.**
  /// `AddChannelWindow` is a non-modal `Window`, so the Watching pane stays
  /// live and interactive for as long as this `await` takes — up to 15
  /// seconds (`liveChannelFeed`'s timeout). If the load ran first and the
  /// fetch second, that whole window would sit between reading the list and
  /// writing it back, and anything the Watching pane wrote in the meantime —
  /// `markSeen` from an Ignore or Add, or `stopWatching` — would be silently
  /// overwritten by the stale copy this call read before the fetch even
  /// started. A stopped channel would come back, and `WatchingModel
  /// .refreshWatches()` would then read it out of `stoppedLogins`, disarming
  /// the exact guard that exists to keep a stopped channel from resurrecting.
  ///
  /// **Edit is not exempt from a stale read, even though `composeEditedWatch()`
  /// runs no fetch of its own.** This used to say it was — "Edit's
  /// load→mutate→save has nothing between them for another write to land
  /// in" — which was true only because the only other writer of
  /// `watches.json` was a person clicking Ignore or Add elsewhere in the
  /// same running app. This stage added two writers that fire on their own
  /// schedule, with nobody touching anything: `WatchPoller.markSubmitted`
  /// marks an archive seen the moment it is queued, and
  /// `AutoDownloadObserver.forget` un-marks one the moment a job fails. The
  /// real window here is not the gap inside this method — it is
  /// `beginEditing(_:)` opening this window through however long someone
  /// takes to press Edit, which is unbounded. A sweep landing in that window
  /// can mark three archives seen; an edit saved after it, still carrying
  /// `editingWatch.seen` from before the sweep, un-marks all three the
  /// moment it saves, and the next sweep re-submits them — duplicate,
  /// unattended downloads of videos already sitting on disk. Read backwards,
  /// a failure `forget()` un-marks during that same window gets re-marked
  /// seen by the stale edit and never returns to the inbox, silently
  /// breaking §6.3's one promise. So `watch.seen` is re-derived from
  /// `existing` — loaded fresh immediately below, not from the snapshot
  /// `beginEditing(_:)` captured — the moment that load lands, before this
  /// ever writes anything back.
  /// The watch `add()` last wrote, so its caller can queue that channel's
  /// backfill with the settings that were actually saved rather than
  /// recomposing them from the form.
  private(set) var savedWatch: Watch?

  /// The archives Add should put straight into the queue.
  ///
  /// **Empty unless automatic downloading is on and the scope is the whole
  /// backfill**, which is exactly the combination whose caption promises
  /// "Every archive shown above is queued and downloaded now". With
  /// automatic off, the same archives become findings and wait for a person
  /// — that is the notify-only half of the design and it is unchanged.
  ///
  /// Filtered to what is downloadable, so a broadcast still in progress is
  /// not queued half-written (`docs/design/channel-watching.md` §5.2).
  var backfillToQueue: [ChannelArchive] {
    guard downloadsAutomatically, scope == .allAvailable,
          case .loaded(let archives) = lookup
    else { return [] }
    return archives.filter { $0.isDownloadable }
  }

  /// Records `ids` as seen for the watch just saved, so the sweep that
  /// follows does not offer them a second time.
  ///
  /// Re-reads the store immediately before writing, the same discipline
  /// `WatchPoller.markSubmitted` keeps and for the same reason: queueing a
  /// backfill awaits a metadata fetch per archive, and the Watching pane's
  /// own writers run across those suspensions.
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

    // Only Add pays for this: `editingWatch.displayName` was already
    // resolved the moment this channel was first added, and re-fetching it
    // on every edit would be a network call for a name that has not
    // changed, to save over a value that already has one. Run before
    // `store.load()` below — see this method's own doc comment for why the
    // order matters.
    if !isEditing {
      watch.displayName = await resolvedDisplayName(for: watch.login)
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

    // Re-derive `seen` from what is actually on disk right now, not from
    // `editingWatch` — see this method's own doc comment above for the two
    // ways a stale `seen` silently misbehaves. Falls back to
    // `editingWatch.seen` only when this login has vanished from the store
    // entirely (stopped while this window sat open) — carrying forward
    // whatever this window last knew is still better than saving an empty
    // `seen` and re-surfacing every archive this channel has ever produced
    // as brand new.
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
