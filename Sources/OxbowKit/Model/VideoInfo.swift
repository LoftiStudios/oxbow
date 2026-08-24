import Foundation

/// One downloadable rendition from the VOD's m3u8 master playlist.
public struct StreamQuality: Sendable, Equatable {
  public var name: String
  public var resolution: String
  public var bitsPerSecond: Int

  public init(name: String, resolution: String, bitsPerSecond: Int) {
    self.name = name
    self.resolution = resolution
    self.bitsPerSecond = bitsPerSecond
  }

  /// Rough output size for this quality over `duration`, from bitrate alone.
  public func estimatedBytes(over duration: Duration) -> Int {
    Int(Double(bitsPerSecond) * duration.asSeconds / 8)
  }
}

/// The video's own metadata plus its available qualities, as parsed from the
/// CLI's `info --format Raw` output.
///
/// `--format Raw` because `--format json` throws `NotImplementedException`
/// upstream (worth a PR there). Raw output is three parts on stdout: a
/// `[STATUS]` banner line, a line of video-info JSON, a line of "moments"
/// JSON, then an m3u8 master playlist — so parsing means finding the first
/// line that is JSON, decoding it, and separately scanning the m3u8 lines
/// that follow for `#EXT-X-STREAM-INF` variants.
public struct VideoInfo: Sendable, Equatable {
  public var streamer: String
  public var title: String
  public var createdAt: Date
  public var duration: Duration
  public var qualities: [StreamQuality]

  public init(
    streamer: String,
    title: String,
    createdAt: Date,
    duration: Duration,
    qualities: [StreamQuality])
  {
    self.streamer = streamer
    self.title = title
    self.createdAt = createdAt
    self.duration = duration
    self.qualities = qualities
  }

  public static func parse(_ output: String) -> VideoInfo? {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false)

    guard let jsonLineIndex = lines.firstIndex(where: isJSONObjectLine),
          let jsonData = lines[jsonLineIndex].data(using: .utf8)
    else { return nil }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let envelope = try? decoder.decode(VideoInfoEnvelope.self, from: jsonData) else {
      return nil
    }
    let video = envelope.data.video

    let m3u8Lines = lines[(jsonLineIndex + 1)...]
    let qualities = Self.parseQualities(from: m3u8Lines)

    return VideoInfo(
      streamer: video.owner.displayName,
      title: video.title,
      createdAt: video.createdAt,
      duration: .seconds(video.lengthSeconds),
      qualities: qualities)
  }

  /// A cheap pre-check so we don't try to JSON-decode m3u8/status lines: real
  /// JSON objects here always start with `{`.
  private static func isJSONObjectLine(_ line: Substring) -> Bool {
    line.first == "{"
  }

  private static func parseQualities<S: Sequence<Substring>>(from lines: S) -> [StreamQuality] {
    var qualities: [StreamQuality] = []
    for line in lines where line.hasPrefix("#EXT-X-STREAM-INF:") {
      let attributesText = line.dropFirst("#EXT-X-STREAM-INF:".count)
      let attributes = Self.parseAttributes(attributesText)

      guard let resolution = attributes["RESOLUTION"] else { continue }
      guard let bandwidthText = attributes["BANDWIDTH"], let bandwidth = Int(bandwidthText) else {
        continue
      }
      let name = attributes["STABLE-VARIANT-ID"] ?? resolution

      qualities.append(StreamQuality(name: name, resolution: resolution, bitsPerSecond: bandwidth))
    }
    return qualities
  }

  /// Splits an `EXT-X-STREAM-INF` attribute list on top-level commas only.
  ///
  /// `CODECS="avc1.640029,mp4a.40.2"` contains a comma *inside* its quoted
  /// value. A plain `split(separator: ",")` would break that field in two and
  /// shift every attribute after it — and it would look correct on any
  /// variant whose CODECS happens to list a single codec. So this walks the
  /// string tracking quote state and only splits where we are not inside `"`.
  private static func parseAttributes(_ text: Substring) -> [String: String] {
    var result: [String: String] = [:]

    var fieldStart = text.startIndex
    var insideQuotes = false
    var index = text.startIndex

    func commitField(endingAt end: String.Index) {
      let field = text[fieldStart..<end]
      guard let equalsIndex = field.firstIndex(of: "=") else { return }
      let key = field[field.startIndex..<equalsIndex]
      var value = field[field.index(after: equalsIndex)...]
      if value.first == "\"", value.last == "\"", value.count >= 2 {
        value = value.dropFirst().dropLast()
      }
      result[String(key)] = String(value)
    }

    while index < text.endIndex {
      let character = text[index]
      if character == "\"" {
        insideQuotes.toggle()
      } else if character == "," && !insideQuotes {
        commitField(endingAt: index)
        fieldStart = text.index(after: index)
      }
      index = text.index(after: index)
    }
    commitField(endingAt: text.endIndex)

    return result
  }
}

/// Mirrors just the fields we need from the CLI's video-info JSON line.
private struct VideoInfoEnvelope: Decodable {
  var data: DataEnvelope

  struct DataEnvelope: Decodable {
    var video: VideoEnvelope
  }

  struct VideoEnvelope: Decodable {
    var title: String
    var createdAt: Date
    var lengthSeconds: Int
    var owner: OwnerEnvelope
  }

  struct OwnerEnvelope: Decodable {
    var displayName: String
  }
}

extension Duration {
  /// This `Duration` expressed as a floating-point number of seconds.
  var asSeconds: Double {
    Double(components.seconds) + Double(components.attoseconds) * 1e-18
  }
}
