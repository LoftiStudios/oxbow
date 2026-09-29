import Foundation

/// The fields of the CLI's chat JSON (`ChatRoot`) that the native renderer reads. Everything
/// else in the file is ignored rather than modelled, so an addition upstream cannot break
/// decoding. docs/design/native-chat-render.md §3.
public struct ChatDocument: Decodable, Sendable, Equatable {
  public var video: Video
  public var comments: [Comment]
  /// The images `chatdownload -E` embeds. Empty for a file downloaded without it.
  public var embeddedData: EmbeddedImages = EmbeddedImages()

  enum CodingKeys: String, CodingKey { case video, comments, embeddedData }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    video = try container.decode(Video.self, forKey: .video)
    comments = try container.decode([Comment].self, forKey: .comments)
    embeddedData = try container.decodeIfPresent(EmbeddedImages.self, forKey: .embeddedData)
      ?? EmbeddedImages()
  }

  public struct Video: Decodable, Sendable, Equatable {
    /// Seconds into the VOD where this chat file begins and ends — the trim, when there is one.
    public var start: Double
    public var end: Double
  }

  public struct Comment: Decodable, Sendable, Equatable {
    public var id: String
    /// 100 ns ticks since 1970, as .NET's `DateTime` holds it: dispersion subtracts these, and
    /// a `Date` would add rounding the CLI does not have.
    public var createdAtTicks: Int64
    /// Seconds from the start of the VOD, not of the file. Whole seconds since Twitch's
    /// November 2022 API change; dispersion recovers the fraction from `createdAt`.
    public var contentOffsetSeconds: Double
    /// Nil makes the CLI skip the comment.
    public var commenter: Commenter?
    public var message: Message

    enum CodingKeys: String, CodingKey {
      case id = "_id"
      case createdAtTicks = "created_at"
      case contentOffsetSeconds = "content_offset_seconds"
      case commenter, message
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decode(String.self, forKey: .id)
      let created = try container.decode(String.self, forKey: .createdAtTicks)
      guard let ticks = ChatDocument.ticks(fromISO8601: created) else {
        throw DecodingError.dataCorruptedError(
          forKey: .createdAtTicks, in: container, debugDescription: "unreadable date \(created)")
      }
      createdAtTicks = ticks
      contentOffsetSeconds = try container.decode(Double.self, forKey: .contentOffsetSeconds)
      commenter = try container.decodeIfPresent(Commenter.self, forKey: .commenter)
      message = try container.decode(Message.self, forKey: .message)
    }
  }

  public struct Commenter: Decodable, Sendable, Equatable {
    public var displayName: String
    public var name: String
    /// Twitch's user id. The CLI recognises some system messages by who sent them.
    public var id: String

    enum CodingKeys: String, CodingKey {
      case displayName = "display_name"
      case name
      case id = "_id"
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      displayName = try container.decode(String.self, forKey: .displayName)
      name = try container.decodeIfPresent(String.self, forKey: .name) ?? displayName
      id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    }
  }

  public struct Message: Decodable, Sendable, Equatable {
    public var body: String
    /// Nil makes the CLI skip the comment, so it is kept nil rather than rebuilt from `body`.
    public var fragments: [Fragment]?
    /// Nil for a viewer who never set one.
    public var userColor: String?
    /// Set on system messages; the CLI skips most of them. See `ChatTimeline.isDrawable`.
    public var noticeID: String?
    /// In the order Twitch lists them, which is the order they are drawn.
    public var badges: [Badge]
    /// Non-zero only on a cheer; only then are words looked up as cheermotes.
    public var bitsSpent: Int

    public struct Badge: Decodable, Sendable, Equatable {
      public var name: String
      public var version: String

      enum CodingKeys: String, CodingKey {
        case name = "_id"
        case version
      }
    }

    enum CodingKeys: String, CodingKey {
      case body, fragments
      case userColor = "user_color"
      case userNoticeParams = "user_notice_params"
      case badges = "user_badges"
      case bitsSpent = "bits_spent"
    }

    private enum NoticeKeys: String, CodingKey { case msgID = "msg_id" }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
      fragments = try container.decodeIfPresent([Fragment].self, forKey: .fragments)
      userColor = try container.decodeIfPresent(String.self, forKey: .userColor)
      badges = try container.decodeIfPresent([Badge].self, forKey: .badges) ?? []
      bitsSpent = try container.decodeIfPresent(Int.self, forKey: .bitsSpent) ?? 0
      if container.contains(.userNoticeParams), try !container.decodeNil(forKey: .userNoticeParams) {
        let notice = try container.nestedContainer(keyedBy: NoticeKeys.self, forKey: .userNoticeParams)
        noticeID = try notice.decodeIfPresent(String.self, forKey: .msgID)
      } else {
        noticeID = nil
      }
    }
  }

  public struct Fragment: Decodable, Sendable, Equatable {
    public var text: String
    /// Set when this fragment is a first-party emote; the renderer draws the image by id.
    public var emoticonID: String?

    init(text: String, emoticonID: String?) {
      self.text = text
      self.emoticonID = emoticonID
    }

    private enum CodingKeys: String, CodingKey { case text, emoticon }
    private enum EmoticonKeys: String, CodingKey { case emoticonID = "emoticon_id" }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      text = try container.decode(String.self, forKey: .text)
      if container.contains(.emoticon), try !container.decodeNil(forKey: .emoticon) {
        let emoticon = try container.nestedContainer(keyedBy: EmoticonKeys.self, forKey: .emoticon)
        emoticonID = try emoticon.decodeIfPresent(String.self, forKey: .emoticonID)
      } else {
        emoticonID = nil
      }
    }
  }

  /// An image as `chatdownload -E` embeds it: encoded bytes (PNG, GIF or WebP, possibly
  /// animated), and the size it is meant to be shown at before `scale` — 2 for the 2× images
  /// Twitch and the emote providers serve.
  public struct EmbeddedImage: Decodable, Sendable, Equatable {
    public var id: String?
    public var name: String?
    public var data: Data
    public var scale: Int
    public var width: Int
    public var height: Int
    /// A 7TV emote drawn over the one before it rather than beside it.
    public var isZeroWidth: Bool

    enum CodingKeys: String, CodingKey {
      case id, name, data, width, height, isZeroWidth
      case scale = "imageScale"
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decodeIfPresent(String.self, forKey: .id)
      name = try container.decodeIfPresent(String.self, forKey: .name)
      data = try container.decode(Data.self, forKey: .data)
      scale = try container.decodeIfPresent(Int.self, forKey: .scale) ?? 1
      width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 0
      height = try container.decodeIfPresent(Int.self, forKey: .height) ?? 0
      isZeroWidth = try container.decodeIfPresent(Bool.self, forKey: .isZeroWidth) ?? false
    }
  }

  public struct EmbeddedImages: Decodable, Sendable, Equatable {
    /// By emote id, as a fragment's `emoticon_id` names it.
    public var firstParty: [String: EmbeddedImage] = [:]
    /// By name, as a word in the message spells it.
    public var thirdParty: [String: EmbeddedImage] = [:]
    /// By badge name, then version.
    public var badges: [String: [String: Data]] = [:]
    /// By prefix, then the lowest bit amount each tier starts at.
    public var cheermotes: [String: [Int: EmbeddedImage]] = [:]

    init() {}

    enum CodingKeys: String, CodingKey { case firstParty, thirdParty, twitchBadges, twitchBits }

    private struct Badge: Decodable {
      var name: String
      var versions: [String: Data]

      private struct Version: Decodable { var bytes: Data }
      enum CodingKeys: String, CodingKey { case name, versions }

      init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        // Current files nest the image under `bytes`; older ones store it bare, and the CLI
        // still reads both.
        if let current = try? container.decode([String: Version].self, forKey: .versions) {
          versions = current.mapValues(\.bytes)
        } else {
          versions = try container.decode([String: Data].self, forKey: .versions)
        }
      }
    }

    private struct Cheermote: Decodable {
      var prefix: String
      var tierList: [String: EmbeddedImage]
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let first = try container.decodeIfPresent([EmbeddedImage].self, forKey: .firstParty) ?? []
      let third = try container.decodeIfPresent([EmbeddedImage].self, forKey: .thirdParty) ?? []
      let badges = try container.decodeIfPresent([Badge].self, forKey: .twitchBadges) ?? []
      let bits = try container.decodeIfPresent([Cheermote].self, forKey: .twitchBits) ?? []
      // First wins on a duplicate, as a dictionary built in list order would not guarantee.
      firstParty = Dictionary(first.compactMap { image in image.id.map { ($0, image) } }) { a, _ in a }
      thirdParty = Dictionary(third.compactMap { image in image.name.map { ($0, image) } }) { a, _ in a }
      self.badges = Dictionary(badges.map { ($0.name, $0.versions) }) { a, _ in a }
      cheermotes = Dictionary(bits.map { cheer in
        (cheer.prefix, Dictionary(cheer.tierList.compactMap { key, image in Int(key).map { ($0, image) } }) { a, _ in a })
      }) { a, _ in a }
    }
  }

  public enum DecodingFailure: Error, Equatable {
    /// The file's schema major version is one this renderer was not written against.
    case unsupportedVersion(Int)
  }

  /// Decodes a chat file, refusing a schema major version other than 1 rather than rendering
  /// something subtly wrong from a format that changed underneath it.
  public static func decode(from data: Data) throws -> ChatDocument {
    let decoder = JSONDecoder()
    let header = try decoder.decode(Header.self, from: data)
    let major = header.fileInfo?.version.major ?? 1
    guard major == 1 else { throw DecodingFailure.unsupportedVersion(major) }
    return try decoder.decode(ChatDocument.self, from: data)
  }

  /// `2026-08-25T23:30:16.964Z` as 100 ns ticks since 1970. Twitch writes fractional seconds
  /// on most timestamps and not on all; .NET keeps up to seven digits, so this does too.
  static func ticks(fromISO8601 string: String) -> Int64? {
    let whole: Substring
    var fraction: Int64 = 0
    if let dot = string.firstIndex(of: ".") {
      guard let zone = string[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" })
      else { return nil }
      let digits = string[string.index(after: dot)..<zone].prefix(7)
      guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let value = Int64(digits) else { return nil }
      fraction = value * Int64(pow(10, Double(7 - digits.count)))
      whole = string[..<dot] + string[zone...]
    } else {
      whole = Substring(string)
    }
    guard let date = ISO8601DateFormatter().date(from: String(whole)) else { return nil }
    return Int64(date.timeIntervalSince1970) * 10_000_000 + fraction
  }

  private struct Header: Decodable {
    var fileInfo: FileInfo?

    struct FileInfo: Decodable {
      var version: Version
      enum CodingKeys: String, CodingKey { case version = "Version" }
    }

    struct Version: Decodable {
      var major: Int
      enum CodingKeys: String, CodingKey { case major = "Major" }
    }

    enum CodingKeys: String, CodingKey { case fileInfo = "FileInfo" }
  }
}
