import Foundation
import Testing

enum Fixture {
  /// Load raw bytes to preserve carriage-return progress delimiters.
  static func bytes(_ name: String) throws -> [UInt8] {
    let url = try #require(Bundle.module.url(
      forResource: name,
      withExtension: nil,
      subdirectory: "Fixtures/cli-output"))
    return try [UInt8](Data(contentsOf: url))
  }

  /// Fixtures that sit directly under `Fixtures/`, not the `cli-output`
  /// subdirectory — e.g. real files written by the bundled FFmpeg.
  static func url(named name: String) throws -> URL {
    try #require(Bundle.module.url(
      forResource: name,
      withExtension: nil,
      subdirectory: "Fixtures"))
  }
}
