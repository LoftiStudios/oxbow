import Foundation
import Testing

@testable import OxbowKit

/// Positions are the CLI's, measured by driving its own `ChatRenderer` at font size 15.
@Suite("Highlight")
struct HighlightTests {

  private let style = ChatTextStyle(width: 342, height: 1026, fontSize: 15)
  private let appearance = ChatAppearance(request: RenderRequest(width: 342, height: 1026, fontSize: 15))

  private func comment(
    _ body: String, name: String = "Foobar", id: String = "1", fragments: [String]? = nil,
    notice: String? = nil, badges: String = "[]") throws -> ChatDocument.Comment
  {
    func quoted(_ s: String) -> String {
      String(data: try! JSONEncoder().encode(s), encoding: .utf8)!
    }
    let fragmentJSON = (fragments ?? [body]).map { #"{"text": \#(quoted($0)), "emoticon": null}"# }
      .joined(separator: ",")
    let noticeJSON = notice.map { #", "user_notice_params": {"msg_id": \#(quoted($0))}"# } ?? ""
    let json = """
      {"video": {"start": 0, "end": 1}, "comments": [{
        "_id": "x", "created_at": "2026-01-01T00:00:00Z", "content_offset_seconds": 0,
        "commenter": {"display_name": \(quoted(name)), "name": "n", "_id": \(quoted(id))},
        "message": {"body": \(quoted(body)), "fragments": [\(fragmentJSON)], "user_color": "#FF69B4",
                    "user_badges": \(badges)\(noticeJSON)}}]}
      """
    return try ChatDocument.decode(from: Data(json.utf8)).comments[0]
  }

  private func layout(_ comment: ChatDocument.Comment) throws -> MessageLayout {
    try #require(MessageLayout(comment: comment, index: 0, offset: 0, style: style, appearance: appearance))
  }

  @Test(arguments: [
    ("Foobar subscribed at Tier 1. They've subscribed for 2 months! ", Highlight.subscribedTier),
    ("Foobar subscribed with Prime. ", .subscribedPrime),
    ("Foobar is gifting 5 Tier 1 Subs to the community! ", .giftedMany),
    ("Foobar gifted a Tier 1 sub to Bazqux! ", .giftedSingle),
    ("Foobar is continuing the Gift Sub they got from Bazqux! ", .continuingGift),
    ("Foobar is continuing the Gift Sub they got from an anonymous user! ", .continuingAnonymousGift),
    ("Foobar is paying forward the Gift they got from Bazqux to the community! ", .payingForward),
    ("Foobar watched 45 consecutive streams and sparked a watch streak! ", .watchStreak),
    ("Foobar: Donated $5.00 USD to support Save the Kids! ", .charityDonation),
    ("Foobar's community sent 12 combos! ", .combo),
    ("Combo started! You have 30 seconds left to join. ", .combo),
    ("bits badge tier notification ", .bitsBadgeTier),
    ("123 raiders from Foobar have joined! ", .raid),
    ("Foobar converted from a Prime sub to a Tier 1 sub! ", .subscribedTier),
  ])
  func classifiesAsTheCLIDoes(body: String, expected: Highlight) throws {
    #expect(Highlight.of(try comment(body)) == expected)
  }

  /// Ordinal and literal, as the CLI's are: a different case, or plain chat, is chat.
  @Test func leavesOrdinaryChatAlone() throws {
    #expect(Highlight.of(try comment("hello there")) == nil)
    #expect(Highlight.of(try comment("foobar subscribed at Tier 1. ")) == nil)
    #expect(Highlight.of(try comment("Foobar converted from a nothing sub! ")) == nil)
  }

  /// Anonymous gifts are recognised by who sent them: Twitch's own accounts.
  @Test func recognisesAnonymousGiftsBySender() throws {
    let body = "An anonymous user gifted a Tier 1 sub to Bazqux! "
    #expect(Highlight.of(try comment(body, name: "AnAnonymousGifter", id: "274598607")) == .giftedAnonymous)
    #expect(Highlight.of(try comment(body, name: "Someone", id: "5")) == nil)
  }

  @Test func legacyChannelPointsHighlightsAreRecognisedByNotice() throws {
    #expect(Highlight.of(try comment("look at me", notice: "highlighted-message")) == .channelPoints)
  }

  @Test func coloursTheBarAsTheCLIDoes() {
    #expect(Highlight.subscribedTier.accentColor == ChatColor(rgb: 0x7B2CF2))
    #expect(Highlight.watchStreak.accentColor == ChatColor(rgb: 0x80808C))
    #expect(Highlight.payingForward.accentColor == ChatColor(rgb: 0x26262C))
    #expect(Highlight.subscribedPrime.iconIsPurple && !Highlight.subscribedTier.iconIsPurple)
  }

  @Test func matchesTheCLIsAccentGeometryAtFontSizeFifteen() {
    #expect(style.accentStroke == 5)
    #expect(style.accentIndent == 20)
    #expect(style.iconSize == 25)
  }

  /// Name at 51 beside the icon, the system text from the next line at 51, and the viewer's own
  /// message back at 23 as a chat line.
  @Test func laysOutAResubWithItsOwnMessage() throws {
    let body = "Foobar subscribed at Tier 1. They've subscribed for 45 months! Hey there chat"
    let layout = try layout(try comment(body))
    let words = layout.words
    #expect(layout.accent?.icon == .star)
    #expect(words[0].text == "Foobar" && words[0].x == 51 && words[0].line == 0)
    #expect(words[0].color == Highlight.purple && words[0].face == .bold)
    #expect(words[1].text == "subscribed" && words[1].x == 51 && words[1].line == 1)
    let own = try #require(words.first { $0.text == "Foobar:" })
    #expect(own.x == 23)
    #expect(words.last?.text == "chat")
  }

  @Test func laysOutAFirstMonthSubAsSystemTextOnly() throws {
    let layout = try layout(try comment("Foobar subscribed at Tier 1. "))
    #expect(layout.lineCount == 2)
    #expect(!layout.words.contains { $0.text == "Foobar:" })
  }

  /// The CLI throws — and aborts the whole render — when a message's fragments do not line up
  /// with its text. Here that message is simply all system text.
  @Test func keepsMisalignedFragmentsAsSystemTextInsteadOfFailing() throws {
    let body = "Foobar subscribed at Tier 1. They've subscribed for 2 months! Kappa hi"
    let layout = try layout(try comment(body, fragments: ["Foobar subscribed at Tier 1. They've subscribed for 2 months! ", "NotInText"]))
    #expect(!layout.words.contains { $0.text == "Foobar:" })
  }

  /// Gifts: the whole body, name included, as plain text at 63 beside the icon (CR:1152-1159).
  @Test func laysOutAGiftBesideItsIcon() throws {
    let layout = try layout(try comment("Foobar gifted a Tier 1 sub to Bazqux! "))
    #expect(layout.accent?.icon == .gift)
    #expect(layout.words[0].text == "Foobar" && layout.words[0].x == 63 && layout.words[0].face == .regular)
  }

  @Test func laysOutARaidWithoutAnIcon() throws {
    let layout = try layout(try comment("123 raiders from Foobar have joined! "))
    #expect(layout.accent?.icon == nil)
    #expect(layout.words[0].text == "123" && layout.words[0].x == 23)
  }

  @Test(arguments: [
    ("1000", "just earned a new 1K Bits badge!"),
    ("25000", "just earned a new 25K Bits badge!"),
    ("100", "just earned a new 100 Bits badge!"),
    // The CLI writes "1000K".
    ("1000000", "just earned a new 1M Bits badge!"),
  ])
  func namesTheBitsBadge(version: String, sentence: String) {
    #expect(MessageLayout.bitsBadgeSentence(version) == sentence)
  }

  @Test func bandsEveryWordOfAChannelPointsHighlightButTheName() throws {
    let layout = try layout(try comment("look at me", notice: "highlighted-message"))
    #expect(layout.words.map(\.isBanded) == [false, true, true, true])
    #expect(layout.words[0].x == 23)
  }
}
