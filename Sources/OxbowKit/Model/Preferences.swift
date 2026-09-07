import Foundation

/// What `Preferences` needs from a key-value store: exactly the five
/// `UserDefaults` members it calls, and nothing else.
///
/// **Constrained to `AnyObject`, deliberately.** `Preferences` is a struct
/// whose copies are meant to share state — `IntakeModel` holds one,
/// `SettingsView` holds another, and a write through either must be visible
/// to the other; `reseedFromPreferences()` and the Settings window only work
/// together because of that sharing. That falls out for free with a
/// reference-type store — `UserDefaults` is a class, and so is
/// `InMemoryPreferenceStore` below — because `Preferences` holds the store by
/// reference even though `Preferences` itself is copied. A `struct`
/// conformance (say, a value-type dictionary wrapper) would silently break
/// this: each copy of `Preferences` would carry its own independent copy of
/// the store's state, and a write through one copy would vanish from every
/// other. `AnyObject` makes that mistake fail to compile instead of failing
/// a handful of tests that read a store written through a different copy of
/// `Preferences`.
public protocol PreferenceStore: AnyObject {
  func string(forKey: String) -> String?
  func bool(forKey: String) -> Bool
  func object(forKey: String) -> Any?
  func set(_ value: Any?, forKey: String)
  func removeObject(forKey: String)
}

/// `UserDefaults` already has every one of these five methods with matching
/// argument labels, so the conformance has nothing to add.
extension UserDefaults: PreferenceStore {}

/// A `PreferenceStore` that never touches disk — a dictionary behind a lock,
/// nothing more.
///
/// **Why this exists.** Tests and SwiftUI previews used to stand up a scratch
/// `UserDefaults(suiteName:)` instead, which is a real `UserDefaults` and
/// therefore writes a real `.plist` to `~/Library/Preferences` the moment
/// anything is set on it — cfprefsd persists a domain's *file* on first write
/// and `removePersistentDomain(forName:)` only clears the domain's
/// *contents*, not the file. That is why the `deinit`-based janitors this
/// type replaces were only a partial fix: they emptied the plist, they never
/// deleted it. A store with no disk underneath it has nothing to leak.
///
/// **Public, and a `final class` rather than an `actor`.** Public because
/// three call sites outside this package need it: `Tests/OxbowKitTests`,
/// `OxbowTests`, and the SwiftUI previews in `Oxbow/`. A plain class rather
/// than an `actor` because `Preferences`' getters and setters are synchronous
/// — an `actor` would force every read through `await`, which `UserDefaults`
/// does not require and callers do not expect. The lock exists only so a
/// store shared between a preview's model and its host window does not race.
public final class InMemoryPreferenceStore: PreferenceStore {
  private var storage: [String: Any] = [:]
  private let lock = NSLock()

  public init() {}

  public func string(forKey key: String) -> String? {
    lock.withLock { storage[key] as? String }
  }

  public func bool(forKey key: String) -> Bool {
    lock.withLock { storage[key] as? Bool ?? false }
  }

  public func object(forKey key: String) -> Any? {
    lock.withLock { storage[key] }
  }

  public func set(_ value: Any?, forKey key: String) {
    lock.withLock { storage[key] = value }
  }

  public func removeObject(forKey key: String) {
    lock.withLock { storage.removeValue(forKey: key) }
  }
}

/// The four standing preferences, and the one flag that says whether the user
/// has ever expressed one.
///
/// **The store is injected, never `.standard` by default at a call site that
/// cannot override it, and never `@AppStorage`.** `OxbowTests` is hosted by
/// the app, so anything reaching for `.standard` during a test run reads and
/// writes the real `studio.lofti.Oxbow` domain — the trap
/// `docs/design/status.md` §9.2 exists to remember. `UpdateModel` takes the
/// same parameter for the same reason.
///
/// **Not `Sendable`.** Neither `UserDefaults` nor `PreferenceStore` promise
/// to be, and nothing needs to send this across an isolation domain: both
/// writers are main-actor views.
public struct Preferences {

  private enum Key {
    static let destination = "defaultDestinationPath"
    static let qualityCap = "defaultQualityCap"
    static let output = "defaultOutput"
    static let chatSize = "defaultChatSize"
    static let hasSavedDefaults = "hasSavedDefaults"
    static let optionsExpanded = "intakeOptionsExpanded"
    static let freeSpaceFloor = "freeSpaceFloor"
  }

  private let store: PreferenceStore
  private let homeDirectory: URL
  private let directoryExists: (URL) -> Bool

  public init(
    store: PreferenceStore = UserDefaults.standard,
    homeDirectory: URL = .homeDirectory,
    directoryExists: @escaping (URL) -> Bool = { url in
      var isDirectory: ObjCBool = false
      let found = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      return found && isDirectory.boolValue
    })
  {
    self.store = store
    self.homeDirectory = homeDirectory
    self.directoryExists = directoryExists
  }

  /// `~/Downloads`. Was `IntakeModel.defaultDestination`, where it was a
  /// static fallback on the model; a factory value belongs with the store it
  /// is the factory value of.
  public static func factoryDestination(homeDirectory: URL) -> URL {
    homeDirectory.appending(path: "Downloads")
  }

  // MARK: - The four

  /// Falls back to `~/Downloads` when what was stored no longer resolves —
  /// see `storedDestinationIsMissing`, which is what makes that visible.
  public var destination: URL {
    get {
      guard let path = store.string(forKey: Key.destination) else {
        return Self.factoryDestination(homeDirectory: homeDirectory)
      }
      let stored = URL(filePath: path)
      guard directoryExists(stored) else {
        return Self.factoryDestination(homeDirectory: homeDirectory)
      }
      return stored
    }
    set {
      store.set(newValue.path, forKey: Key.destination)
      recordSave()
    }
  }

  public var qualityCap: QualityCap {
    get {
      store.string(forKey: Key.qualityCap).flatMap(QualityCap.init(rawValue:)) ?? .best
    }
    set {
      store.set(newValue.rawValue, forKey: Key.qualityCap)
      recordSave()
    }
  }

  public var output: DownloadOutput {
    get {
      store.string(forKey: Key.output).flatMap(DownloadOutput.init(rawValue:)) ?? .default
    }
    set {
      store.set(newValue.rawValue, forKey: Key.output)
      recordSave()
    }
  }

  public var chatSize: ChatSize {
    get {
      store.string(forKey: Key.chatSize).flatMap(ChatSize.init(rawValue:)) ?? .default
    }
    set {
      store.set(newValue.rawValue, forKey: Key.chatSize)
      recordSave()
    }
  }

  /// Below this much free space on a watch's destination volume, automatic
  /// downloading declines to start a job rather than risk it.
  ///
  /// **Stored as an `Int64` count of bytes — that is a storage format, not
  /// an implementation detail.** A saved value is meaningless without the
  /// unit it was written in; if this is ever changed to kilobytes or a
  /// fractional gigabyte, every value already on disk silently means
  /// something else the moment the new build reads it back. `QualityCap`'s
  /// raw strings carry the identical trap for the same reason — see its own
  /// comment.
  public var freeSpaceFloor: Int64 {
    get {
      (store.object(forKey: Key.freeSpaceFloor) as? Int64) ?? Self.factoryFreeSpaceFloor
    }
    set {
      store.set(newValue, forKey: Key.freeSpaceFloor)
      recordSave()
    }
  }

  /// The factory free-space floor: what Oxbow will not spend, on top of what
  /// the download itself is priced at.
  ///
  /// **Lowered from 49 GB to 10 GB on 2026-09-07, because the old number was
  /// counting the job twice.** 49 GB came from `docs/design/disk-preflight
  /// .md` §5's worked example — a six-hour 1080p60 job with chat peaks at
  /// about 49 GB across source, chat-render intermediate and composite — and
  /// the reasoning was that a floor below a single job's peak never fires in
  /// time to help. That was correct when the floor was the *only* protection.
  ///
  /// It is not any more. `AutoDownloadPolicy` prices every batch with
  /// `BackfillEstimate`, whose sum is peak-aware in exactly the same way
  /// (`Σ delivered + max transient overhead`), and refuses any batch that
  /// would take the volume below this. So the job's peak is already
  /// subtracted before this number is consulted, and setting the floor to a
  /// second copy of that peak reserved a worst-case 1080p-with-chat job's
  /// worth of room in order to decline a 300 MB 360p one.
  ///
  /// What is left for the floor to do is keep the machine usable — leave
  /// room for the system, not for the download. **10 GB**, which is also
  /// already a rung on the settings picker. Anyone wanting the old behaviour
  /// can pick 49 GB there, and someone on a very full disk can pick more.
  public static let factoryFreeSpaceFloor: Int64 = 10_000_000_000

  /// Whether the intake's options panel opens expanded.
  ///
  /// **Its own stored value, not derived from `hasSavedDefaults`.** Deriving
  /// it means someone who never opts in gets the panel forced open on every
  /// launch with no way to stop it, which turns informative into nagging.
  ///
  /// Deliberately does **not** call `recordSave()`: collapsing a panel is not
  /// expressing a preference about downloads.
  public var optionsPanelIsExpanded: Bool {
    get { store.object(forKey: Key.optionsExpanded) as? Bool ?? true }
    set { store.set(newValue, forKey: Key.optionsExpanded) }
  }

  // MARK: - Whether anything has been expressed

  /// **Stored, never inferred by comparing against the factory values.**
  /// Someone can deliberately save defaults identical to the factory ones and
  /// must still be treated as configured; inference would greet them as a
  /// first-timer forever.
  ///
  /// Set by any write, from either writer — the intake's checkbox and the
  /// Settings window alike. It means *the user has expressed a preference*,
  /// not *the checkbox was used*.
  public var hasSavedDefaults: Bool {
    store.bool(forKey: Key.hasSavedDefaults)
  }

  /// A destination was stored and is no longer there. False when nothing was
  /// ever stored — that is not the same situation and must not draw a warning.
  public var storedDestinationIsMissing: Bool {
    guard let path = store.string(forKey: Key.destination) else { return false }
    return !directoryExists(URL(filePath: path))
  }

  public mutating func restoreDefaults() {
    for key in [Key.destination, Key.qualityCap, Key.output, Key.chatSize,
                Key.hasSavedDefaults, Key.optionsExpanded, Key.freeSpaceFloor] {
      store.removeObject(forKey: key)
    }
  }

  private func recordSave() {
    store.set(true, forKey: Key.hasSavedDefaults)
  }
}
