import Foundation

/// The synchronous store used by `Preferences`. Requires reference semantics so copies held by
/// intake and Settings share writes.
public protocol PreferenceStore: AnyObject {
  func string(forKey: String) -> String?
  func bool(forKey: String) -> Bool
  func object(forKey: String) -> Any?
  func set(_ value: Any?, forKey: String)
  func removeObject(forKey: String)
}

extension UserDefaults: PreferenceStore {}

/// A locked, in-memory store for tests and previews. Named `UserDefaults` suites still leave
/// plist files after `removePersistentDomain`; this store never touches disk. A class keeps the
/// synchronous `Preferences` API while the lock protects shared access.
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

/// Persistent download defaults. Inject the store: hosted app tests would otherwise write the
/// real preferences domain through `.standard` or `@AppStorage`. Not Sendable; callers use it
/// on the main actor.
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

  /// Factory destination: `~/Downloads`.
  public static func factoryDestination(homeDirectory: URL) -> URL {
    homeDirectory.appending(path: "Downloads")
  }

  // MARK: - Download defaults

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

  /// Minimum free bytes to leave on a watch's destination volume. Persisted as `Int64` bytes;
  /// changing the unit requires migration.
  public var freeSpaceFloor: Int64 {
    get {
      (store.object(forKey: Key.freeSpaceFloor) as? Int64) ?? Self.factoryFreeSpaceFloor
    }
    set {
      store.set(newValue, forKey: Key.freeSpaceFloor)
      recordSave()
    }
  }

  /// System headroom left after `BackfillEstimate` accounts for the batch's peak disk use. The
  /// 10 GB floor does not need to reserve another job's worth of space.
  public static let factoryFreeSpaceFloor: Int64 = 10_000_000_000

  /// Stores intake expansion independently of download defaults. Does not call `recordSave()`:
  /// opening or collapsing options does not save download preferences.
  public var optionsPanelIsExpanded: Bool {
    get { store.object(forKey: Key.optionsExpanded) as? Bool ?? true }
    set { store.set(newValue, forKey: Key.optionsExpanded) }
  }

  // MARK: - Saved state

  /// Records an explicit save, even when values equal factory defaults. Set by
  /// download-preference writes from both intake and Settings.
  public var hasSavedDefaults: Bool {
    store.bool(forKey: Key.hasSavedDefaults)
  }

  /// A stored destination no longer exists. False when none was saved.
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
