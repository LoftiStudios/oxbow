import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@MainActor
@Suite("Update model")
struct UpdateModelTests {

  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  /// Counts calls as well as answering them, so "did not check" is provable
  /// rather than inferred from an unchanged state.
  private actor Stub {
    private let outcome: Result<UpdateCheck.Outcome, any Error>
    private(set) var calls = 0

    init(_ outcome: Result<UpdateCheck.Outcome, any Error>) { self.outcome = outcome }

    func run() async throws -> UpdateCheck.Outcome {
      calls += 1
      return try outcome.get()
    }
  }

  private struct Offline: Error {}

  private func defaults() throws -> UserDefaults {
    let suite = try #require(UserDefaults(suiteName: "UpdateModelTests-\(UUID().uuidString)"))
    return suite
  }

  private func available(_ version: String) throws -> UpdateCheck.Outcome {
    .available(
      try #require(ReleaseVersion(version)),
      try #require(URL(string: "https://github.com/loftiStudios/oxbow/releases/tag/v\(version)")))
  }

  private func model(
    defaults: UserDefaults,
    stub: Stub,
    now: Date? = nil)
    -> UpdateModel
  {
    let clock = now ?? self.now
    return UpdateModel(defaults: defaults, now: { clock }, performCheck: { try await stub.run() })
  }

  // MARK: - The automatic check

  @Test func automaticCheckSurfacesANewerRelease() async throws {
    let stub = Stub(.success(try available("0.3.0")))
    let model = model(defaults: try defaults(), stub: stub)

    await model.checkAutomatically()

    #expect(model.state == .available(
      try #require(ReleaseVersion("0.3.0")),
      try #require(URL(string: "https://github.com/loftiStudios/oxbow/releases/tag/v0.3.0"))))
  }

  @Test func automaticCheckDoesNotRunAgainWithinTheInterval() async throws {
    let defaults = try defaults()
    let stub = Stub(.success(.upToDate))

    await model(defaults: defaults, stub: stub).checkAutomatically()
    await model(defaults: defaults, stub: stub, now: now.addingTimeInterval(3600))
      .checkAutomatically()

    #expect(await stub.calls == 1)
  }

  /// Silence is the whole point of the automatic path: launching with the
  /// wi-fi off must not paint anything.
  @Test func automaticCheckStaysSilentWhenItFails() async throws {
    let stub = Stub(.failure(Offline()))
    let model = model(defaults: try defaults(), stub: stub)

    await model.checkAutomatically()

    #expect(await stub.calls == 1)
    #expect(model.state == .idle)
  }

  /// A failed check must not consume the day's slot, or one launch in a cafe
  /// with a captive portal costs the user 24 hours of not being told.
  @Test func aFailedCheckDoesNotStartTheInterval() async throws {
    let defaults = try defaults()

    await model(defaults: defaults, stub: Stub(.failure(Offline()))).checkAutomatically()

    let second = Stub(.success(try available("0.3.0")))
    await model(defaults: defaults, stub: second, now: now.addingTimeInterval(60))
      .checkAutomatically()

    #expect(await second.calls == 1)
  }

  // MARK: - The menu item

  /// Pressing it is an explicit request, so the throttle does not apply.
  @Test func manualCheckRunsEvenInsideTheInterval() async throws {
    let defaults = try defaults()
    let stub = Stub(.success(.upToDate))

    await model(defaults: defaults, stub: stub).checkAutomatically()
    await model(defaults: defaults, stub: stub).checkManually()

    #expect(await stub.calls == 2)
  }

  /// The only proof a user has that the feature works at all.
  @Test func manualCheckSaysSoWhenAlreadyCurrent() async throws {
    let model = model(defaults: try defaults(), stub: Stub(.success(.upToDate)))
    await model.checkManually()
    #expect(model.state == .upToDate)
  }

  @Test func manualCheckReportsItsFailure() async throws {
    let model = model(defaults: try defaults(), stub: Stub(.failure(Offline())))
    await model.checkManually()

    guard case .failed = model.state else {
      Issue.record("expected .failed, got \(model.state)")
      return
    }
  }

  // MARK: - Dismissal

  @Test func dismissingHidesTheBannerImmediately() async throws {
    let model = model(defaults: try defaults(), stub: Stub(.success(try available("0.3.0"))))
    await model.checkAutomatically()

    model.dismiss()

    #expect(model.state == .idle)
  }

  @Test func aDismissedVersionStaysHiddenOnTheNextLaunch() async throws {
    let defaults = try defaults()
    let first = model(defaults: defaults, stub: Stub(.success(try available("0.3.0"))))
    await first.checkAutomatically()
    first.dismiss()

    let second = model(
      defaults: defaults,
      stub: Stub(.success(try available("0.3.0"))),
      now: now.addingTimeInterval(UpdatePolicy.interval + 60))
    await second.checkAutomatically()

    #expect(second.state == .idle)
  }

  /// The menu item ignores a previous dismissal. Pressing it is a fresh,
  /// explicit question, and answering "up to date" while a newer release sits
  /// on the releases page would be a lie the user has no way to see through.
  @Test func manualCheckIgnoresAPreviousDismissal() async throws {
    let defaults = try defaults()
    let first = model(defaults: defaults, stub: Stub(.success(try available("0.3.0"))))
    await first.checkAutomatically()
    first.dismiss()

    let second = model(defaults: defaults, stub: Stub(.success(try available("0.3.0"))))
    await second.checkManually()

    #expect(second.state == .available(
      try #require(ReleaseVersion("0.3.0")),
      try #require(URL(string: "https://github.com/loftiStudios/oxbow/releases/tag/v0.3.0"))))
  }

  @Test func aDismissalDoesNotSuppressALaterVersion() async throws {
    let defaults = try defaults()
    let first = model(defaults: defaults, stub: Stub(.success(try available("0.3.0"))))
    await first.checkAutomatically()
    first.dismiss()

    let second = model(
      defaults: defaults,
      stub: Stub(.success(try available("0.4.0"))),
      now: now.addingTimeInterval(UpdatePolicy.interval + 60))
    await second.checkAutomatically()

    #expect(second.state == .available(
      try #require(ReleaseVersion("0.4.0")),
      try #require(URL(string: "https://github.com/loftiStudios/oxbow/releases/tag/v0.4.0"))))
  }
}
