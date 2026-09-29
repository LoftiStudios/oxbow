import Foundation

/// The system messages the CLI draws in its accented layout — subs, gifts, raids — rather than as
/// chat. Detection is `HighlightIcons.GetHighlightType` (HI:97-189), ported literally: ordinal
/// comparisons, trailing spaces included, in its order.
enum Highlight: Sendable, Equatable {
  case subscribedTier, subscribedPrime, giftedSingle, giftedMany, giftedAnonymous
  case continuingGift, continuingAnonymousGift, payingForward, watchStreak, charityDonation
  case combo, bitsBadgeTier, raid
  /// A channel-points highlighted message. Only legacy chat files mark these, through
  /// `user_notice_params`; current downloads never write it.
  case channelPoints

  static func of(_ comment: ChatDocument.Comment) -> Highlight? {
    if comment.message.noticeID == "highlighted-message" { return .channelPoints }
    guard let commenter = comment.commenter else { return nil }
    let body = comment.message.body
    guard !body.isEmpty else { return nil }
    let name = commenter.displayName

    if body.hasOrdinalPrefix(name) {
      let rest = String(body.utf16.dropFirst(name.utf16.count))!
      if rest.hasOrdinalPrefix(" subscribed at Tier") { return .subscribedTier }
      if rest.hasOrdinalPrefix(" subscribed with Prime") { return .subscribedPrime }
      if rest.hasOrdinalPrefix(" is gifting") { return .giftedMany }
      if rest.hasOrdinalPrefix(" gifted a Tier") { return .giftedSingle }
      if rest.hasOrdinalPrefix(" is continuing the Gift Sub they got from") {
        return rest.hasOrdinalSuffix("from an anonymous user! ") ? .continuingAnonymousGift : .continuingGift
      }
      if rest.hasOrdinalPrefix(" is paying forward the Gift they got from") { return .payingForward }
      if rest.contains(" consecutive streams "), rest.contains(" and sparked a watch streak! ") {
        return .watchStreak
      }
      if rest.hasOrdinalPrefix(": Donated "),
         String(rest.utf16.dropFirst(10))!.contains(" to support ")
      {
        return .charityDonation
      }
      if rest.hasOrdinalPrefix("'s community sent"), rest.hasOrdinalSuffix("! ") { return .combo }
      if rest.hasOrdinalPrefix(" converted from a") {
        // HI:142-156: decided here, one way or the other; never falls through.
        let slice = String(rest.utf16.dropFirst(17))!
        // The CLI's lookbehind `(?<= (?:Prime|Tier \d) sub to a )(?:Prime|Tier \d)`, as a capture:
        // Swift's Regex has no lookbehind.
        guard let match = slice.firstMatch(of: /\ (?:Prime|Tier \d) sub to a (Prime|Tier \d)/)
        else { return nil }
        let target = String(match.output.1)
        if target == "Prime" { return .subscribedPrime }
        return target.hasPrefix("Tier ") ? .subscribedTier : nil
      }
    }

    if body.hasOrdinalPrefix("Combo started! You have "), body.hasOrdinalSuffix("left to join. ") {
      return .combo
    }
    if body == "bits badge tier notification " { return .bitsBadgeTier }
    if let first = body.first, first.isWholeNumber, body.hasOrdinalSuffix(" have joined! "),
       let raiders = Self.raiders(from: name), body.firstMatch(of: raiders) != nil
    {
      return .raid
    }
    // Twitch's own accounts: AnAnonymousGifter, Twitch, and Valorant's promotion (HI:171-186).
    if ["274598607", "12826"].contains(commenter.id),
       body.firstMatch(of: /^An anonymous user (?:gifted a|is gifting \d{1,4}) Tier \d/) != nil
    {
      return .giftedAnonymous
    }
    if ["12826", "490592527"].contains(commenter.id), body.hasOrdinalSuffix("'s gift! "),
       body.firstMatch(of: /^We added \d+ Gift Subs (?:AND \d+ Bonus Gift Subs )?to/) != nil
    {
      return .giftedMany
    }
    return nil
  }

  /// The bar down the comment's left edge (CR:908-931).
  var accentColor: ChatColor {
    switch self {
    case .watchStreak, .combo, .channelPoints: ChatColor(rgb: 0x80808C)
    case .payingForward: ChatColor(rgb: 0x26262C)
    default: Self.purple
    }
  }

  /// Nil for the types the CLI draws without one (HI:193-268). The gift bomb's icon is a PNG the
  /// CLI can only read from its download cache, so in an offline render it draws a blank square;
  /// the single-gift box stands in for it here.
  var icon: HighlightIcon? {
    switch self {
    case .subscribedTier: .star
    case .subscribedPrime: .crown
    case .giftedSingle, .giftedMany: .gift
    case .giftedAnonymous, .continuingAnonymousGift: .ghost
    case .bitsBadgeTier: .gem
    case .watchStreak: .flame
    case .charityDonation: .charity
    case .continuingGift, .payingForward, .combo, .raid, .channelPoints: nil
    }
  }

  /// Prime's crown is always purple; every other icon takes the message colour (HI:198).
  var iconIsPurple: Bool { self == .subscribedPrime }

  /// Twitch's purple, as the CLI hard-codes it (CR:32).
  static let purple = ChatColor(rgb: 0x7B2CF2)
}

extension Highlight {
  /// `^\d+ raiders from {name} have joined! ` — the name escaped, where the CLI interpolates it
  /// raw (HI:165-169). Twitch names are word characters, so the two agree on real data.
  fileprivate static func raiders(from name: String) -> Regex<AnyRegexOutput>? {
    try? Regex(#"^\d+ raiders from "# + NSRegularExpression.escapedPattern(for: name) + #" have joined! "#)
  }
}

extension String {
  /// .NET's `StartsWith(string, Ordinal)`: code unit by code unit, where Swift's `hasPrefix`
  /// compares canonically equivalent characters.
  func hasOrdinalPrefix(_ prefix: String) -> Bool { utf16.starts(with: prefix.utf16) }

  func hasOrdinalSuffix(_ suffix: String) -> Bool { utf16.reversed().starts(with: suffix.utf16.reversed()) }
}
