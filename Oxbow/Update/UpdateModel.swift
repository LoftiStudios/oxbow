import Foundation
import Observation
import OxbowKit

/// Update-check state and persisted timing/dismissal values; injected checking avoids network
/// access in tests.
@MainActor
@Observable
final class UpdateModel {

  enum State: Equatable {
    /// Automatic checks remain silent on failure or no update.
    case idle
    case available(ReleaseVersion, URL)
    /// Only ever reached from the menu item.
    case upToDate
    /// Only ever reached from the menu item.
    case failed(String)
  }

  private(set) var state: State = .idle

  /// Inject PreferenceStore so tests can use memory rather than leaving UserDefaults suite
  /// files behind.
  private let store: PreferenceStore
  private let now: () -> Date
  private let performCheck: @Sendable () async throws -> UpdateCheck.Outcome

  init(
    store: PreferenceStore = UserDefaults.standard,
    now: @escaping () -> Date = Date.init,
    performCheck: @escaping @Sendable () async throws -> UpdateCheck.Outcome)
  {
    self.store = store
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

  /// Remember the dismissed version; newer releases still notify.
  func dismiss() {
    if case .available(let version, _) = state {
      store.set(version.description, forKey: Key.skippedVersion)
    }
    state = .idle
  }

  private func run(isManual: Bool) async {
    do {
      let outcome = try await performCheck()

      // Record successful checks only, allowing a failed network attempt to retry next launch.
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
    get { store.object(forKey: Key.lastChecked) as? Date }
    set { store.set(newValue, forKey: Key.lastChecked) }
  }

  private var skippedVersion: ReleaseVersion? {
    store.string(forKey: Key.skippedVersion).flatMap(ReleaseVersion.init)
  }
}

extension UpdateModel {
  /// Live UpdateCheck adapter using URLSession.
  static func live() -> UpdateModel {
    // Ephemeral session with a 15-second timeout; avoid persisted payloads and stale responses
    // to manual checks.
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.waitsForConnectivity = false
    let session = URLSession(configuration: configuration)

    // Read bare semver, not the formatted About version line.
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
