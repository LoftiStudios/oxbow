import Foundation
import Observation
import OxbowKit

/// Owns the update check's state and the two small pieces of it that outlive
/// the process.
///
/// The check itself is injected as a closure rather than built here, so this
/// type knows nothing about GitHub, `URLSession`, or JSON — and its tests need
/// no network. `AppComposition` supplies the real one.
@MainActor
@Observable
final class UpdateModel {

  enum State: Equatable {
    /// Nothing to say. Every automatic check that finds nothing, and every
    /// automatic check that fails, ends here — the launch path is silent by
    /// design.
    case idle
    case available(ReleaseVersion, URL)
    /// Only ever reached from the menu item.
    case upToDate
    /// Only ever reached from the menu item.
    case failed(String)
  }

  private(set) var state: State = .idle

  private let defaults: UserDefaults
  private let now: () -> Date
  private let performCheck: @Sendable () async throws -> UpdateCheck.Outcome

  init(
    defaults: UserDefaults = .standard,
    now: @escaping () -> Date = Date.init,
    performCheck: @escaping @Sendable () async throws -> UpdateCheck.Outcome)
  {
    self.defaults = defaults
    self.now = now
    self.performCheck = performCheck
  }

  /// The launch-time check. Throttled, and silent about everything except an
  /// update the user has not already dismissed.
  func checkAutomatically() async {
    guard UpdatePolicy.shouldCheckAutomatically(now: now(), lastChecked: lastChecked) else {
      return
    }
    await run(isManual: false)
  }

  /// The Check for Updates… menu item. Never throttled, never silent.
  func checkManually() async {
    await run(isManual: true)
  }

  /// Dismissing means "not this one" — the version is remembered so the next
  /// launch stays quiet, and any version above it still gets through.
  func dismiss() {
    if case .available(let version, _) = state {
      defaults.set(version.description, forKey: Key.skippedVersion)
    }
    state = .idle
  }

  private func run(isManual: Bool) async {
    do {
      let outcome = try await performCheck()

      // Recorded only on success, so a launch with no network retries on the
      // next one instead of spending the day's slot on a check that never
      // reached GitHub.
      lastChecked = now()

      // A manual check ignores the stored dismissal: the user just asked.
      let skipped = isManual ? nil : skippedVersion
      if UpdatePolicy.shouldPresent(outcome, skipping: skipped),
         case .available(let version, let url) = outcome
      {
        state = .available(version, url)
      } else {
        state = isManual ? .upToDate : .idle
      }
    } catch {
      state = isManual ? .failed(error.localizedDescription) : .idle
    }
  }

  // MARK: - Stored state

  private enum Key {
    static let lastChecked = "UpdateLastChecked"
    static let skippedVersion = "UpdateSkippedVersion"
  }

  private var lastChecked: Date? {
    get { defaults.object(forKey: Key.lastChecked) as? Date }
    set { defaults.set(newValue, forKey: Key.lastChecked) }
  }

  private var skippedVersion: ReleaseVersion? {
    defaults.string(forKey: Key.skippedVersion).flatMap(ReleaseVersion.init)
  }
}

extension UpdateModel {
  /// The real thing, wired to GitHub over `URLSession`.
  ///
  /// This adapter is the one part of the feature nothing covers: it is glue
  /// between `UpdateCheck` (tested against a stub transport) and `URLSession`
  /// (Apple's). There is no logic in it to get wrong beyond the cast, and a
  /// test for it would be a test of `URLSession`.
  static func live() -> UpdateModel {
    // Ephemeral so a release payload is never written to disk, and so a
    // cached 200 can never answer a check the user explicitly asked for.
    // Fifteen seconds because the manual check has someone waiting on it —
    // the default sixty is a minute of a menu item having done nothing
    // visible.
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.waitsForConnectivity = false
    let session = URLSession(configuration: configuration)

    // Read raw rather than through `AboutInfo`, which deliberately exposes
    // only the composed "Version 0.2.1 (73)" sentence. What is needed here is
    // the bare semver.
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

    let check = UpdateCheck(currentVersion: version) { request in
      let (data, response) = try await session.data(for: request)
      guard let response = response as? HTTPURLResponse else {
        throw URLError(.badServerResponse)
      }
      return (data, response)
    }
    return UpdateModel { try await check.run() }
  }
}
