/// A username's colour before it is made readable: the viewer's own when Twitch recorded one,
/// otherwise one of the CLI's fifteen defaults (CR:33, 1737-1739).
///
/// The CLI picks the default with `string.GetHashCode()`, which .NET randomises per process, so
/// its choice changes on every render (docs/upstream-candidates.md §1). This picks with a stable
/// hash instead: the same palette, one colour per viewer, forever. Matching the CLI here is not
/// possible, only matching its palette.
enum UsernameColor {
  static let defaults: [UInt32] = [
    0xFF0000, 0x0000FF, 0x00FF00, 0xB22222, 0xFF7F50, 0x9ACD32, 0xFF4500, 0x2E8B57, 0xDAA520,
    0xD2691E, 0x5F9EA0, 0x1E90FF, 0xFF69B4, 0x8A2BE2, 0x00FF7F,
  ]

  static func color(for comment: ChatDocument.Comment) -> ChatColor {
    if let own = comment.message.userColor, let parsed = ChatColor(hex: own) {
      return parsed
    }
    let name = comment.commenter?.displayName ?? ""
    return ChatColor(rgb: defaults[Int(fnv1a(name) % UInt32(defaults.count))])
  }

  /// FNV-1a over UTF-16, as .NET hashes strings, minus the per-process seed.
  static func fnv1a(_ text: String) -> UInt32 {
    var hash: UInt32 = 2_166_136_261
    for unit in text.utf16 {
      hash ^= UInt32(unit)
      hash &*= 16_777_619
    }
    return hash
  }
}
