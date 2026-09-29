import Foundation

/// The fields of the CLI's chat JSON (`ChatRoot`) that the native renderer reads. Everything
/// else in the file is ignored rather than modelled, so an addition upstream cannot break
/// decoding. docs/design/native-chat-render.md §3.
public struct ChatDocument: Decodable, Sendable, Equatable {
  public var video: Video
  public var comments: [Comment]

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

    enum CodingKeys: String, CodingKey {
      case displayName = "display_name"
      case name
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

    enum CodingKeys: String, CodingKey {
      case body, fragments
      case userColor = "user_color"
      case userNoticeParams = "user_notice_params"
    }

    private enum NoticeKeys: String, CodingKey { case msgID = "msg_id" }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
      fragments = try container.decodeIfPresent([Fragment].self, forKey: .fragments)
      userColor = try container.decodeIfPresent(String.self, forKey: .userColor)
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
