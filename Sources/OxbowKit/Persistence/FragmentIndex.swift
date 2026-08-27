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
        guard let ext = try handle.read(upToCount: 8), ext.count == 8 else { break }
        boxSize = Int(ext.reduce(0) { $0 << 8 | UInt64($1) })
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
        guard let ext = try handle.read(upToCount: 8), ext.count == 8 else { break }
        boxSize = Int(ext.reduce(0) { $0 << 8 | UInt64($1) })
      } else if boxSize == 0 {
        boxSize = size - offset
      }

      guard boxSize >= 8, offset + boxSize <= size else { break }
      if type == "moov" { return true }
      offset += boxSize
    }
    return false
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
