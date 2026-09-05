import Foundation
import Testing
@testable import OxbowKit

@Suite("Watch")
struct WatchTests {

  private let settings = Watch.Settings(
    destinationPath: "/Users/x/Downloads", qualityCap: .p1080,
    output: .videoWithChat, chatSize: .medium)

  private func watch(seen: Set<String> = []) -> Watch {
    Watch(login: "ninja", displayName: "Ninja", settings: settings,
          downloadsAutomatically: false, seen: seen)
  }

  private func archive(_ id: String, status: ChannelArchive.Status = .recorded) -> ChannelArchive {
    ChannelArchive(id: id, title: "t", duration: .seconds(60),
                   publishedAt: Date(timeIntervalSince1970: 0), status: status, thumbnailURL: nil)
  }

  // MARK: Scope seeds the seen-set, and is not a stored mode

  @Test("only new marks everything currently listed as already seen")
  func onlyNewSeedsEverything() {
    let seeded = watch().seeded(withScope: .onlyNew, from: [archive("1"), archive("2")])
    #expect(seeded.seen == ["1", "2"])
    #expect(seeded.findings(in: [archive("1"), archive("2")]).isEmpty)
  }

  @Test("all available marks nothing, so everything listed is a finding")
  func allAvailableSeedsNothing() {
    let seeded = watch().seeded(withScope: .allAvailable, from: [archive("1"), archive("2")])
    #expect(seeded.seen.isEmpty)
    #expect(seeded.findings(in: [archive("1"), archive("2")]).map(\.id) == ["1", "2"])
  }

  @Test("only new seeds from a live broadcast too, so it is not re-offered later")
  func onlyNewSeedsFromLiveToo() {
    // A RECORDING node is not downloadable, but it is listed. If scope
    // skipped it, the archive would appear as brand new the moment it
    // finished — correct for allAvailable, wrong for onlyNew, whose promise
    // is that nothing already on the channel appears.
    let seeded = watch().seeded(withScope: .onlyNew, from: [archive("1", status: .recording)])
    #expect(seeded.seen == ["1"])
  }

  // MARK: Findings

  @Test("a seen archive is not a finding")
  func seenIsNotAFinding() {
    #expect(watch(seen: ["1"]).findings(in: [archive("1"), archive("2")]).map(\.id) == ["2"])
  }

  @Test("findings include a live broadcast, because a human may still choose it")
  func findingsIncludeLive() {
    // §5.2 forbids anything *unattended* queueing a RECORDING. It does not
    // hide it from a person; the auto-download path filters on
    // `isDownloadable`, and this does not.
    #expect(watch().findings(in: [archive("1", status: .recording)]).map(\.id) == ["1"])
  }

  @Test("marking is additive and returns a new value")
  func markingIsAdditive() {
    #expect(watch(seen: ["1"]).marking(["2", "3"]).seen == ["1", "2", "3"])
  }

  // MARK: Login normalisation

  @Test("a channel URL reduces to its login")
  func loginFromURL() {
    #expect(Watch.normalisedLogin("https://www.twitch.tv/lilbadsnacks/videos") == "lilbadsnacks")
    #expect(Watch.normalisedLogin("twitch.tv/Ninja") == "ninja")
    #expect(Watch.normalisedLogin("  Ninja  ") == "ninja")
  }

  @Test("anything that is not a Twitch login is rejected")
  func rejectsNonLogins() {
    // The login is interpolated into the GraphQL query, so this is the only
    // thing standing between a pasted string and the query body.
    #expect(Watch.normalisedLogin("evil-twitch.tv") == nil)
    #expect(Watch.normalisedLogin("nin\"ja") == nil)
    #expect(Watch.normalisedLogin("") == nil)
    #expect(Watch.normalisedLogin("https://youtube.com/ninja") == nil)
  }

  @Test("a URL addressing a reserved route is not a channel, and is rejected")
  func rejectsReservedRoutes() {
    // These are exactly what `TwitchLink.parse` treats as a video or a bare
    // VOD id (`Oxbow/Intake/TwitchLink.swift`) — the first path segment is
    // real, but it is not a login.
    #expect(Watch.normalisedLogin("https://www.twitch.tv/videos/2862926638") == nil)
    #expect(Watch.normalisedLogin("https://www.twitch.tv/directory/game/Fortnite") == nil)
    #expect(Watch.normalisedLogin("https://twitch.tv/settings/profile") == nil)
    #expect(Watch.normalisedLogin("https://twitch.tv/popout/ninja/chat") == nil)
    #expect(Watch.normalisedLogin("https://twitch.tv/subscriptions") == nil)
    #expect(Watch.normalisedLogin("https://twitch.tv/downloads") == nil)
    #expect(Watch.normalisedLogin("https://twitch.tv/u/ninja") == nil)
    #expect(Watch.normalisedLogin("https://twitch.tv/team/staff") == nil)
  }

  @Test("clips.twitch.tv is rejected outright, not read as a channel path")
  func rejectsClipsHost() {
    #expect(Watch.normalisedLogin("https://clips.twitch.tv/SoftYawningPeachKappa") == nil)
  }

  @Test("a bare all-digit token is accepted, because a numeric login is legal")
  func acceptsBareNumericLogin() {
    // `TwitchLink.parse` reads a bare all-digit token as a VOD id, and that
    // divergence from this function is real — but a numeric string is a
    // legal Twitch login (`docs/twitch-channel-api.md` never rules it out),
    // so rejecting it here would be wrong for its own sake, not merely
    // inconsistent with the other parser. See M1 in the review notes.
    #expect(Watch.normalisedLogin("2862926638") == "2862926638")
  }

  @Test("the host is matched case-insensitively")
  func hostIsCaseInsensitive() {
    #expect(Watch.normalisedLogin("https://TWITCH.TV/ninja") == "ninja")
    #expect(Watch.normalisedLogin("https://Twitch.Tv/ninja") == "ninja")
  }

  @Test("the 4-25 character length bound is enforced at both edges")
  func lengthBoundIsEnforced() {
    #expect(Watch.normalisedLogin("abc") == nil)                          // 3: too short
    #expect(Watch.normalisedLogin("abcd") == "abcd")                      // 4: shortest legal
    #expect(Watch.normalisedLogin(String(repeating: "a", count: 25)) == String(repeating: "a", count: 25))
    #expect(Watch.normalisedLogin(String(repeating: "a", count: 26)) == nil) // 26: too long
  }
}
