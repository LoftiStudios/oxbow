import Foundation

/// The four standing preferences, and the one flag that says whether the user
/// has ever expressed one.
///
/// **`UserDefaults` is injected, never `.standard` by default at a call site
/// that cannot override it, and never `@AppStorage`.** `OxbowTests` is hosted
/// by the app, so anything reaching for `.standard` during a test run reads
/// and writes the real `studio.lofti.Oxbow` domain — the trap
/// `docs/design/status.md` §9.2 exists to remember. `UpdateModel` takes the
/// same parameter for the same reason.
///
/// **Not `Sendable`.** `UserDefaults` is not, and nothing needs to send this
/// across an isolation domain: both writers are main-actor views.
public struct Preferences {

  private enum Key {
    static let destination = "defaultDestinationPath"
    static let qualityCap = "defaultQualityCap"
    static let output = "defaultOutput"
    static let chatSize = "defaultChatSize"
    static let hasSavedDefaults = "hasSavedDefaults"
  }

  private let defaults: UserDefaults
  private let homeDirectory: URL
  private let directoryExists: (URL) -> Bool

  public init(
    defaults: UserDefaults = .standard,
    homeDirectory: URL = .homeDirectory,
    directoryExists: @escaping (URL) -> Bool = { url in
      var isDirectory: ObjCBool = false
      let found = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      return found && isDirectory.boolValue
    })
  {
    self.defaults = defaults
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
      guard let path = defaults.string(forKey: Key.destination) else {
        return Self.factoryDestination(homeDirectory: homeDirectory)
      }
      let stored = URL(filePath: path)
      guard directoryExists(stored) else {
        return Self.factoryDestination(homeDirectory: homeDirectory)
      }
      return stored
    }
    set {
      defaults.set(newValue.path, forKey: Key.destination)
      recordSave()
    }
  }

  public var qualityCap: QualityCap {
    get {
      defaults.string(forKey: Key.qualityCap).flatMap(QualityCap.init(rawValue:)) ?? .best
    }
    set {
      defaults.set(newValue.rawValue, forKey: Key.qualityCap)
      recordSave()
    }
  }

  public var output: DownloadOutput {
    get {
      defaults.string(forKey: Key.output).flatMap(DownloadOutput.init(rawValue:)) ?? .default
    }
    set {
      defaults.set(newValue.rawValue, forKey: Key.output)
      recordSave()
    }
  }

  public var chatSize: ChatSize {
    get {
      defaults.string(forKey: Key.chatSize).flatMap(ChatSize.init(rawValue:)) ?? .default
    }
    set {
      defaults.set(newValue.rawValue, forKey: Key.chatSize)
      recordSave()
    }
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
    defaults.bool(forKey: Key.hasSavedDefaults)
  }

  /// A destination was stored and is no longer there. False when nothing was
  /// ever stored — that is not the same situation and must not draw a warning.
  public var storedDestinationIsMissing: Bool {
    guard let path = defaults.string(forKey: Key.destination) else { return false }
    return !directoryExists(URL(filePath: path))
  }

  public mutating func restoreDefaults() {
    for key in [Key.destination, Key.qualityCap, Key.output, Key.chatSize,
                Key.hasSavedDefaults] {
      defaults.removeObject(forKey: key)
    }
  }

  private func recordSave() {
    defaults.set(true, forKey: Key.hasSavedDefaults)
  }
}
