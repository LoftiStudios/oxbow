import Foundation

/// Builds fragmented-MP4 byte layouts for fragment-index tests, without a
/// real encoder — just the box shapes the parser reads.
enum FragmentBuilder {

  /// Big-endian box: [size][type][payload]
  static func box(_ type: String, _ payload: Data) -> Data {
    var out = Data()
    var size = UInt32(8 + payload.count).bigEndian
    withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
    out.append(contentsOf: Array(type.utf8))
    out.append(payload)
    return out
  }

  /// A `moof` holding one `traf` holding one `trun` declaring `samples`.
  /// version 0, flags 0 — sample_count is the only field we read.
  static func moof(samples: UInt32) -> Data {
    var trun = Data([0, 0, 0, 0])                       // version + flags
    var count = samples.bigEndian
    withUnsafeBytes(of: &count) { trun.append(contentsOf: $0) }
    return box("moof", box("traf", box("trun", trun)))
  }

  static func fragmentedFile(_ counts: [UInt32], trailingGarbage: Int = 0) -> Data {
    var data = box("ftyp", Data(repeating: 0, count: 8))
    data.append(box("moov", Data(repeating: 0, count: 8)))
    for c in counts {
      data.append(moof(samples: c))
      data.append(box("mdat", Data(repeating: 0xAB, count: 32)))
    }
    if trailingGarbage > 0 {
      data.append(Data(repeating: 0xFF, count: trailingGarbage))
    }
    return data
  }

  /// Build mvhd with version-specific time/duration widths: 32-bit for v0, 64-bit for v1.
  static func mvhd(timescale: UInt32, duration: UInt64, version: UInt8) -> Data {
    var payload = Data([version, 0, 0, 0])
    if version == 1 {
      payload.append(Data(repeating: 0, count: 16))     // creation + modification
      var scale = timescale.bigEndian
      withUnsafeBytes(of: &scale) { payload.append(contentsOf: $0) }
      var value = duration.bigEndian
      withUnsafeBytes(of: &value) { payload.append(contentsOf: $0) }
    } else {
      payload.append(Data(repeating: 0, count: 8))      // creation + modification
      var scale = timescale.bigEndian
      withUnsafeBytes(of: &scale) { payload.append(contentsOf: $0) }
      var value = UInt32(truncatingIfNeeded: duration).bigEndian
      withUnsafeBytes(of: &value) { payload.append(contentsOf: $0) }
    }
    return box("mvhd", payload)
  }

  /// An ordinary (non-fragmented) file carrying only what the duration
  /// reader looks at: `ftyp`, then a `moov` whose first child is `mvhd`.
  static func fileWithDuration(
    timescale: UInt32, duration: UInt64, version: UInt8 = 0) -> Data
  {
    var data = box("ftyp", Data(repeating: 0, count: 8))
    data.append(box("moov", mvhd(timescale: timescale, duration: duration, version: version)))
    return data
  }

  /// Extended-size box beyond Int.max, exercising malformed-header handling without a
  /// conversion trap.
  static func oversizedBox(_ type: String, largesize: UInt64 = .max) -> Data {
    var out = Data()
    var size = UInt32(1).bigEndian
    withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
    out.append(contentsOf: Array(type.utf8))
    var big = largesize.bigEndian
    withUnsafeBytes(of: &big) { out.append(contentsOf: $0) }
    return out
  }

  static func write(_ data: Data) throws -> URL {
    let url = URL(filePath: NSTemporaryDirectory())
      .appending(path: "frag-\(UUID().uuidString).mp4")
    try data.write(to: url)
    return url
  }
}
