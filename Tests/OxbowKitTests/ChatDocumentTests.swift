import Foundation
import Testing

@testable import OxbowKit

@Suite("Chat document")
struct ChatDocumentTests {

  /// Shaped like a real `chatdownload` file: every field it writes, of which the renderer reads
  /// few.
  private let sample = """
    {
      "FileInfo": {"Version": {"Major": 1, "Minor": 4, "Patch": 0}},
      "streamer": {"name": "s", "login": "s", "id": 1},
      "clipper": null,
      "video": {"id": "2856361990", "start": 9000, "end": 9180, "length": 27440},
      "comments": [
        {
          "_id": "a", "created_at": "2026-08-25T23:30:16.964Z", "channel_id": "1",
          "content_type": "video", "content_id": "2856361990", "content_offset_seconds": 9002,
          "commenter": {"display_name": "CatLookingSideways", "_id": "7", "name": "catlookingsideways",
                        "bio": null, "created_at": "2020-01-01T00:00:00Z", "updated_at": "2020-01-01T00:00:00Z",
                        "logo": "x"},
          "message": {
            "body": "W camera man SoonerLater", "bits_spent": 0,
            "fragments": [{"text": "W camera man ", "emoticon": null},
                          {"text": "SoonerLater", "emoticon": {"emoticon_id": "2113050"}}],
            "user_badges": [], "user_color": "#1E90FF", "emoticons": []
          }
        },
        {
          "_id": "b", "created_at": "2026-08-25T23:30:17Z", "channel_id": "1",
          "content_type": "video", "content_id": "2856361990", "content_offset_seconds": 9003,
          "commenter": {"display_name": "danielsalgado0804", "_id": "8", "name": "danielsalgado0804"},
          "message": {"body": "ayo", "fragments": null, "user_color": null}
        }
      ],
      "embeddedData": {"thirdParty": [], "firstParty": [], "twitchBadges": [], "twitchBits": []}
    }
    """

  @Test func decodesTheFieldsTheRendererReads() throws {
    let document = try ChatDocument.decode(from: Data(sample.utf8))

    #expect(document.video.start == 9000)
    #expect(document.video.end == 9180)
    #expect(document.comments.count == 2)

    let first = document.comments[0]
    #expect(first.id == "a")
    #expect(first.contentOffsetSeconds == 9002)
    #expect(first.commenter?.displayName == "CatLookingSideways")
    #expect(first.message.userColor == "#1E90FF")
    #expect(first.message.fragments?.map(\.text) == ["W camera man ", "SoonerLater"])
    #expect(first.message.fragments?.map(\.emoticonID) == [nil, "2113050"])
  }

  /// Twitch writes milliseconds on most timestamps and not all; dispersion subtracts them in
  /// 100 ns ticks, as .NET does.
  @Test func readsTimestampsWithAndWithoutFractionalSecondsTo100Nanoseconds() throws {
    let document = try ChatDocument.decode(from: Data(sample.utf8))
    #expect(document.comments[1].createdAtTicks - document.comments[0].createdAtTicks == 360_000)
    #expect(ChatDocument.ticks(fromISO8601: "1970-01-01T00:00:01.1234567Z") == 11_234_567)
    #expect(ChatDocument.ticks(fromISO8601: "1970-01-01T00:00:00Z") == 0)
  }

  @Test func aViewerWithNoColourDecodesAsNil() throws {
    let document = try ChatDocument.decode(from: Data(sample.utf8))
    #expect(document.comments[1].message.userColor == nil)
  }

  /// The CLI skips a comment with null fragments rather than drawing its body.
  @Test func aMessageWithNoFragmentsKeepsThemNil() throws {
    let document = try ChatDocument.decode(from: Data(sample.utf8))
    #expect(document.comments[1].message.fragments == nil)
  }

  @Test func refusesAnUnknownMajorVersion() {
    let future = sample.replacingOccurrences(of: "\"Major\": 1", with: "\"Major\": 2")
    #expect(throws: ChatDocument.DecodingFailure.unsupportedVersion(2)) {
      try ChatDocument.decode(from: Data(future.utf8))
    }
  }
}
