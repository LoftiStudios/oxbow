import Foundation

/// What piece 0 remembers about the video it was composited from.
///
/// A resumed job re-downloads its inputs, and Twitch does not guarantee they
/// come back the same: VOD sections are muted for DMCA after the fact,
/// renditions get re-encoded, VODs get trimmed. Half a composite from before
/// such a change and half from after produces a file with a discontinuity and
/// no error anywhere. This is what makes that refuse loudly instead.
///
/// Byte length plus duration, because geometry drift already fails on its own
/// — `hstack` refuses mismatched heights — so the case worth catching is
/// same-geometry, different-content, and a mute changes the byte length.
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
