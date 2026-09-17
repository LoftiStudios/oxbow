import Foundation

/// How much of a fragmented MP4 is usable, and how many frames that is.
public struct FragmentIndex: Sendable, Equatable {
  /// Byte length of the complete prefix — everything up to and including the
  /// last `mdat` whose whole box is present.
  public var completeBytes: Int
  /// Samples declared by the `trun` of every complete fragment.
  public var frameCount: Int

  public init(completeBytes: Int, frameCount: Int) {
    self.completeBytes = completeBytes
    self.frameCount = frameCount
  }
}

/// Reads the complete prefix and declared frame count of a possibly torn fragmented MP4.
/// Composite pieces are video-only, so no per-track bookkeeping is needed.
public enum FragmentedMP4 {

  /// A `moof` announces a fragment; the `mdat` after it holds the samples.
  /// A `moof` with no `mdat` describes frames that are not on disk, so its
  /// count is discarded and the cut goes before it.
  public static func index(of url: URL) throws -> FragmentIndex {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = Int(try handle.seekToEnd())

    var offset = 0
    var complete = 0
    var frames = 0
    var pending: Int?

    while offset + 8 <= size {
      try handle.seek(toOffset: UInt64(offset))
      guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }

      var boxSize = Int(header[header.startIndex ..< header.startIndex + 4]
        .reduce(0) { $0 << 8 | UInt32($1) })
      let type = String(decoding: header[header.startIndex + 4 ..< header.startIndex + 8],
                        as: UTF8.self)

      if boxSize == 1 {
        guard let extended = try largesize(handle: handle) else { break }
        boxSize = extended
      } else if boxSize == 0 {
        boxSize = size - offset
      }

      guard boxSize >= 8, offset + boxSize <= size else { break }

      switch type {
      case "moof":
        pending = try sampleCount(handle: handle, start: offset + 8, end: offset + boxSize)
      case "mdat":
        if let samples = pending {
          frames += samples
          complete = offset + boxSize
          pending = nil
        }
      default:
        if pending == nil { complete = max(complete, offset + boxSize) }
      }

      offset += boxSize
    }

    return FragmentIndex(completeBytes: complete, frameCount: frames)
  }

  /// Truncates `url` to its complete prefix and returns the resulting index.
  /// Safe to call on an untorn file: the prefix is then the whole file.
  @discardableResult
  public static func repair(_ url: URL) throws -> FragmentIndex {
    let index = try index(of: url)
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: UInt64(index.completeBytes))
    return index
  }

  /// Checks for a complete top-level `moov`, indicating a finished non-fragmented sidecar. Do
  /// not use for fragmented pieces: `+empty_moov` writes it before samples. Use `index(of:)`
  /// for those.
  public static func hasCompleteMoov(at url: URL) throws -> Bool {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = Int(try handle.seekToEnd())

    var offset = 0
    while offset + 8 <= size {
      try handle.seek(toOffset: UInt64(offset))
      guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }

      var boxSize = Int(header[header.startIndex ..< header.startIndex + 4]
        .reduce(0) { $0 << 8 | UInt32($1) })
      let type = String(decoding: header[header.startIndex + 4 ..< header.startIndex + 8],
                        as: UTF8.self)

      if boxSize == 1 {
        guard let extended = try largesize(handle: handle) else { break }
        boxSize = extended
      } else if boxSize == 0 {
        boxSize = size - offset
      }

      guard boxSize >= 8, offset + boxSize <= size else { break }
      if type == "moov" { return true }
      offset += boxSize
    }
    return false
  }

  /// Reads movie duration from `moov` → `mvhd` without decoding. Used to clamp chat seeks:
  /// seeking beyond its end can produce an empty composite with exit 0. Nil means unreadable,
  /// not zero; callers must not clamp unknown durations to the start.
  public static func duration(of url: URL) throws -> Duration? {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = Int(try handle.seekToEnd())

    guard let moov = try box(named: "moov", handle: handle, start: 0, end: size),
          let mvhd = try box(named: "mvhd", handle: handle, start: moov.start, end: moov.end)
    else { return nil }

    try handle.seek(toOffset: UInt64(mvhd.start))
    guard let version = try handle.read(upToCount: 1)?.first else { return nil }

    // Version 0 uses 32-bit times/duration; version 1 uses 64-bit values. Timescale stays
    // 32-bit. Choosing the wrong layout yields plausible but incorrect durations.
    let timesWidth = version == 1 ? 16 : 8
    try handle.seek(toOffset: UInt64(mvhd.start + 4 + timesWidth))

    guard let scaleBytes = try handle.read(upToCount: 4), scaleBytes.count == 4 else { return nil }
    let timescale = scaleBytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    guard timescale > 0 else { return nil }

    let durationWidth = version == 1 ? 8 : 4
    guard let valueBytes = try handle.read(upToCount: durationWidth),
          valueBytes.count == durationWidth
    else { return nil }
    let value = valueBytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }

    return .seconds(Double(value) / Double(timescale))
  }

  /// The payload bounds of the first child box of `type` between `start` and
  /// `end`, or `nil` if there is none. Shares the header decoding — extended
  /// `largesize`, `size == 0` meaning "to the end" — with the walks above.
  private static func box(
    named type: String, handle: FileHandle, start: Int, end: Int)
    throws -> (start: Int, end: Int)?
  {
    var offset = start
    while offset + 8 <= end {
      try handle.seek(toOffset: UInt64(offset))
      guard let header = try handle.read(upToCount: 8), header.count == 8 else { return nil }

      var boxSize = Int(header[header.startIndex ..< header.startIndex + 4]
        .reduce(0) { $0 << 8 | UInt32($1) })
      let name = String(decoding: header[header.startIndex + 4 ..< header.startIndex + 8],
                        as: UTF8.self)

      if boxSize == 1 {
        guard let extended = try largesize(handle: handle) else { return nil }
        boxSize = extended
      } else if boxSize == 0 {
        boxSize = end - offset
      }

      guard boxSize >= 8, offset + boxSize <= end else { return nil }
      if name == type { return (offset + 8, offset + boxSize) }
      offset += boxSize
    }
    return nil
  }

  /// Reads 64-bit `largesize` when box size is 1. Use `Int(exactly:)` so oversized malformed
  /// headers return nil rather than trap beyond the reach of `try?`.
  private static func largesize(handle: FileHandle) throws -> Int? {
    guard let ext = try handle.read(upToCount: 8), ext.count == 8 else { return nil }
    let raw = ext.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    return Int(exactly: raw)
  }

  /// Descends `moof` → `traf` → `trun` and reads `sample_count`, which sits
  /// immediately after the version/flags word.
  private static func sampleCount(handle: FileHandle, start: Int, end: Int) throws -> Int? {
    var offset = start
    while offset + 8 <= end {
      try handle.seek(toOffset: UInt64(offset))
      guard let header = try handle.read(upToCount: 8), header.count == 8 else { return nil }
      let boxSize = Int(header[header.startIndex ..< header.startIndex + 4]
        .reduce(0) { $0 << 8 | UInt32($1) })
      let type = String(decoding: header[header.startIndex + 4 ..< header.startIndex + 8],
                        as: UTF8.self)
      guard boxSize >= 8, offset + boxSize <= end else { return nil }

      if type == "traf" {
        if let found = try sampleCount(handle: handle, start: offset + 8, end: offset + boxSize) {
          return found
        }
      } else if type == "trun" {
        try handle.seek(toOffset: UInt64(offset + 12))
        guard let count = try handle.read(upToCount: 4), count.count == 4 else { return nil }
        return Int(count.reduce(0) { $0 << 8 | UInt32($1) })
      }
      offset += boxSize
    }
    return nil
  }
}
