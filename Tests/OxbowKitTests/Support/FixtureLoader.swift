import Foundation
import Testing

enum Fixture {
  /// Loads a captured CLI output fixture as raw bytes.
  ///
  /// Raw bytes, not `String`, because the `\r` placement is the entire point
  /// and must not pass through any newline-normalising API.
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
