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

/// Reads the complete prefix of a fragmented MP4 without a subprocess.
///
/// Resume needs two numbers from a possibly-torn file: where to cut, and how
/// many frames survived. Both are in the container — `trun` declares a
/// fragment's sample count — so this is parsing rather than decoding. The
/// composite writes its pieces video-only, so there is exactly one track and
/// no per-track bookkeeping is needed.
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

  /// Whether `url` has a complete top-level `moov` box.
  ///
  /// An encoder writes `moov` last, after every sample — that is exactly
  /// why an ordinary (non-fragmented) MP4 is not crash-safe: a process
  /// killed mid-write never reaches it, and nothing after the fact can
  /// rebuild it without re-encoding. This is the cheap, no-decode way to
  /// tell "finished writing" from "interrupted", used for the composite's
  /// audio sidecar, which — unlike a piece — has none of the fragmentation
  /// that makes a partial write recoverable. See docs/design/resume.md §4.
  ///
  /// **Only means "finished writing" for a non-fragmented file like the
  /// sidecar.** A `+empty_moov` piece places `moov` at the very head, before
  /// any sample data, by design (`fragmented-output.md` §3) — so this would
  /// read `true` on a piece that is still being written and torn mid-fragment.
  /// This type's other half, `index(of:)`, is what pieces are checked with;
  /// do not call this one on a fragmented file.
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

  /// How long the movie is, from `moov` → `mvhd`, or `nil` if that cannot be
  /// read.
  ///
  /// Exists so a resumed composite can tell whether its chat render is long
  /// enough to seek into. Seeking a render past its own end yields zero
  /// frames, `hstack` has no last frame to repeat, and the piece comes out
  /// empty while FFmpeg still exits 0 — see docs/design/resume.md §12. The
  /// clamp needs a duration, and we bundle no `ffprobe` to ask for one, so
  /// this reads it the same no-decode way the rest of this type works.
  ///
  /// **`nil` is not zero.** A caller clamping a seek must be able to tell
  /// "this render is N seconds long" from "I could not find out": the first
  /// says clamp, the second says leave the seek alone and let the existing
  /// behaviour stand. Returning zero for an unreadable header would clamp
  /// every resume to the very start of the chat.
  ///
  /// Reads the *movie* header, not a track's. A composite's inputs are
  /// single-track for this purpose and `mvhd` is the one duration that is
  /// always present at a fixed place; walking `trak` → `mdia` → `mdhd` would
  /// buy per-track precision this has no use for.
  public static func duration(of url: URL) throws -> Duration? {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = Int(try handle.seekToEnd())

    guard let moov = try box(named: "moov", handle: handle, start: 0, end: size),
          let mvhd = try box(named: "mvhd", handle: handle, start: moov.start, end: moov.end)
    else { return nil }

    try handle.seek(toOffset: UInt64(mvhd.start))
    guard let version = try handle.read(upToCount: 1)?.first else { return nil }

    // version 0 writes 32-bit creation/modification times, version 1 writes
    // 64-bit ones. Timescale is always 32-bit; duration follows it and
    // matches the version's width. Reading one layout as the other does not
    // fail — it returns a plausible, wrong number — so the version byte is
    // load-bearing, not a formality.
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

  /// The 64-bit `largesize` that follows a box header declaring `size == 1`.
  /// `Int(exactly:)`, not a bare `Int(...)`: a `largesize` past `Int.max`
  /// would otherwise trap, and a trap is not something the `try?` at every
  /// call site of `index(of:)`/`hasCompleteMoov` can catch — same class of
  /// bug as the `FileHandle.write` crash fixed earlier on this branch. A
  /// `largesize` this codebase will never actually see in a legitimate file
  /// just reads as "not a valid box" instead, the same as any other
  /// malformed header.
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
