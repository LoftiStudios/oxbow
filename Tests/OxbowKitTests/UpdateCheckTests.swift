import Foundation
import Testing
@testable import OxbowKit

@Suite("Update check")
struct UpdateCheckTests {

  /// Keep unused response fields to prove decoding tolerates them.
  private func payload(
    tag: String,
    htmlURL: String = "https://github.com/LoftiStudios/oxbow/releases/tag/v0.3.0")
    -> Data
  {
    Data("""
      {
        "url": "https://api.github.com/repos/LoftiStudios/oxbow/releases/12345",
        "html_url": "\(htmlURL)",
        "tag_name": "\(tag)",
        "name": "Oxbow \(tag)",
        "draft": false,
        "prerelease": false,
        "published_at": "2026-09-01T12:00:00Z",
        "assets": []
      }
      """.utf8)
  }

  /// Captures what the checker asked for, so the request itself can be
  /// asserted on rather than taken on faith.
  private actor Recorder {
    var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
  }

  private func outcome(
    currentVersion: String = "0.2.1",
    body: Data,
    status: Int = 200,
    recorder: Recorder? = nil)
    async throws -> UpdateCheck.Outcome
  {
    let check = UpdateCheck(currentVersion: currentVersion) { request in
      await recorder?.record(request)
      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: status,
        httpVersion: nil,
        headerFields: nil)
      return (body, try #require(response))
    }
    return try await check.run()
  }

  // MARK: - What it decides

  @Test func offersAnUpdateWhenTheLatestReleaseIsNewer() async throws {
    let outcome = try await outcome(currentVersion: "0.2.1", body: payload(tag: "v0.3.0"))
    #expect(outcome == .available(
      try #require(ReleaseVersion("0.3.0")),
      try #require(URL(string: "https://github.com/LoftiStudios/oxbow/releases/tag/v0.3.0"))))
  }

  @Test func staysQuietWhenTheLatestReleaseIsTheRunningVersion() async throws {
    #expect(try await outcome(currentVersion: "0.2.1", body: payload(tag: "v0.2.1")) == .upToDate)
  }

  /// Unpublishing may move latest backwards; never offer a downgrade.
  @Test func neverOffersAnOlderReleaseThanTheOneRunning() async throws {
    #expect(try await outcome(currentVersion: "0.3.0", body: payload(tag: "v0.2.1")) == .upToDate)
  }

  @Test func staysQuietWhenTheTagCannotBeParsed() async throws {
    #expect(try await outcome(body: payload(tag: "nightly")) == .upToDate)
  }

  /// An unparseable local version must not invent an update.
  @Test func staysQuietWhenTheRunningVersionCannotBeParsed() async throws {
    #expect(try await outcome(currentVersion: "", body: payload(tag: "v9.9.9")) == .upToDate)
  }

  // MARK: - The request it makes

  @Test func asksForTheLatestReleaseOfTheConfiguredRepository() async throws {
    let recorder = Recorder()
    _ = try await outcome(body: payload(tag: "v0.2.1"), recorder: recorder)
    let request = try #require(await recorder.requests.first)
    #expect(request.url?.absoluteString
      == "https://api.github.com/repos/LoftiStudios/oxbow/releases/latest")
  }

  /// Assert User-Agent explicitly because a stub would not reproduce GitHub's rejection.
  @Test func identifiesItselfWithAUserAgent() async throws {
    let recorder = Recorder()
    _ = try await outcome(body: payload(tag: "v0.2.1"), recorder: recorder)
    let request = try #require(await recorder.requests.first)
    let agent = try #require(request.value(forHTTPHeaderField: "User-Agent"))
    #expect(agent.contains("Oxbow"))
  }

  @Test func asksForThePinnedApiMediaType() async throws {
    let recorder = Recorder()
    _ = try await outcome(body: payload(tag: "v0.2.1"), recorder: recorder)
    let request = try #require(await recorder.requests.first)
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
  }

  // MARK: - How it fails

  /// HTTP failures remain distinct from a successful no-update result.
  @Test func reportsAnUnsuccessfulStatusRatherThanDecodingTheErrorBody() async {
    await #expect(throws: UpdateCheckError.server(status: 403)) {
      try await outcome(body: Data(#"{"message":"API rate limit exceeded"}"#.utf8), status: 403)
    }
  }

  @Test func propagatesATransportFailure() async {
    struct Offline: Error {}
    let check = UpdateCheck(currentVersion: "0.2.1") { _ in throw Offline() }
    await #expect(throws: Offline.self) { try await check.run() }
  }

  @Test func reportsAMalformedPayload() async {
    await #expect(throws: (any Error).self) {
      try await outcome(body: Data("not json".utf8))
    }
  }
}

@Suite("Update check error")
struct UpdateCheckErrorTests {

  /// Manual checks must show a readable error description.
  @Test func namesTheRateLimitRatherThanItsNumber() {
    #expect(UpdateCheckError.server(status: 403).localizedDescription
      .localizedCaseInsensitiveContains("rate limit"))
  }

  @Test func reportsAnyOtherStatusByNumber() {
    #expect(UpdateCheckError.server(status: 500).localizedDescription.contains("500"))
  }
}
