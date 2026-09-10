import Foundation
import Testing
@testable import OxbowKit

@Suite("Channel profile")
struct ChannelProfileDecodingTests {

  private func feed(body: Data, status: Int = 200) -> ChannelFeed {
    ChannelFeed(fetch: { request in
      (body, HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    })
  }

  @Test("decodes the display name and the avatar URL")
  func decodesBoth() async throws {
    let body = Data("""
      {"data":{"user":{"displayName":"Hall_of_Tech",\
      "profileImageURL":"https://static-cdn.jtvnw.net/x-profile_image-300x300.png"}}}
      """.utf8)
    let profile = try await feed(body: body).profile(forLogin: "hall_of_tech")
    #expect(profile.displayName == "Hall_of_Tech")
    #expect(profile.avatarURL?.absoluteString.hasSuffix("300x300.png") == true)
  }

  /// A channel with no avatar set is ordinary, not an error — the name is
  /// what the caller actually needs, and a nil here just means no image.
  @Test("a missing avatar is nil, not a failure")
  func missingAvatarIsNil() async throws {
    let body = Data(#"{"data":{"user":{"displayName":"Ninja"}}}"#.utf8)
    let profile = try await feed(body: body).profile(forLogin: "ninja")
    #expect(profile.displayName == "Ninja")
    #expect(profile.avatarURL == nil)
  }

  @Test("an unknown channel still throws noSuchChannel")
  func unknownChannelThrows() async throws {
    let body = Data(#"{"data":{"user":null}}"#.utf8)
    do {
      _ = try await feed(body: body).profile(forLogin: "nobody")
      Issue.record("expected a throw")
    } catch let error as ChannelFeedError {
      #expect(error == .noSuchChannel)
    }
  }

  /// `docs/twitch-channel-api.md` §9.2: the field accepts any width and
  /// returns an interpolated URL, but the CDN serves only this set. A width
  /// outside it is a 404 that looks like a successful request.
  @Test("the requested avatar width is one the CDN actually serves")
  func avatarWidthIsServable() {
    #expect([28, 50, 70, 150, 300, 600].contains(ChannelFeed.avatarWidth))
  }

  @Test("the query asks for the avatar at that width")
  func queryCarriesTheWidth() {
    let query = ChannelFeed.profileQuery(login: "ninja")
    #expect(query.contains("profileImageURL(width: \(ChannelFeed.avatarWidth))"))
    #expect(query.contains("displayName"))
  }
}
