import Foundation

/// Byte length and duration recorded with the first composite piece. Rejects changed
/// re-downloads that geometry checks alone would miss, such as a newly muted VOD.
public struct SourceFingerprint: Codable, Sendable, Equatable {
  public var byteCount: Int
  public var duration: Duration

  public init(byteCount: Int, duration: Duration) {
    self.byteCount = byteCount
    self.duration = duration
  }

  public static func of(_ url: URL, duration: Duration) throws -> SourceFingerprint {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    return SourceFingerprint(byteCount: size, duration: duration)
  }

  public func write(to url: URL) throws {
    try JSONEncoder().encode(self).write(to: url, options: .atomic)
  }

  public static func read(from url: URL) throws -> SourceFingerprint {
    try JSONDecoder().decode(SourceFingerprint.self, from: Data(contentsOf: url))
  }

  public func matches(_ other: SourceFingerprint) -> Bool {
    byteCount == other.byteCount && duration == other.duration
  }
}
