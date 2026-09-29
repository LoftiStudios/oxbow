import Foundation
import Testing
@testable import OxbowKit

@Suite("Render request decoding")
struct RenderRequestDecodingTests {

  /// Start from today's encoding and remove the key, so the legacy shape cannot drift from
  /// the real one by hand.
  private func legacy() throws -> Data {
    let current = try JSONEncoder().encode(RenderRequest(destination: URL(filePath: "/tmp/o.mp4")))
    var object = try #require(JSONSerialization.jsonObject(with: current) as? [String: Any])
    object.removeValue(forKey: "isOffline")
    return try JSONSerialization.data(withJSONObject: object)
  }

  /// A render queued before the flag existed read a chat file downloaded without embedded
  /// images. It must keep fetching them: offline, it would render with every emote missing.
  @Test func aRenderPersistedBeforeTheFlagExistedStaysOnline() throws {
    let request = try JSONDecoder().decode(RenderRequest.self, from: legacy())
    #expect(!request.isOffline)
    #expect(request.destination == URL(filePath: "/tmp/o.mp4"))
  }

  @Test func roundTripsTheFlag() throws {
    let original = RenderRequest(isOffline: true)
    let decoded = try JSONDecoder().decode(
      RenderRequest.self, from: JSONEncoder().encode(original))
    #expect(decoded.isOffline)
  }
}
