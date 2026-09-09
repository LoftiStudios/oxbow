import Foundation
import Testing
import OxbowKit
@testable import Oxbow

@Suite("Submission recording")
@MainActor
struct SubmissionRecordingTests {

  private func temporaryDirectory() -> URL {
    URL.temporaryDirectory.appending(path: "submission-record-\(UUID().uuidString)")
  }

  private var fetched: VideoInfoFetcher.Fetched {
    VideoInfoFetcher.Fetched(
      info: VideoInfo(
        streamer: "WheelyF", login: "wheelyf", title: "day 46",
        createdAt: Date(timeIntervalSince1970: 1_757_000_000),
        duration: .seconds(10203),
        qualities: [StreamQuality(name: "1080p60", resolution: "1920x1080", bitsPerSecond: 6_000_000)],
        thumbnailURLs: [
          URL(string: "https://cdn/a.jpg")!, URL(string: "https://cdn/b.jpg")!,
          URL(string: "https://cdn/c.jpg")!, URL(string: "https://cdn/d.jpg")!,
        ]),
      payload: "{\"data\":{\"video\":{}}}\n{\"moments\":true}\n#EXTM3U\n")
  }

  @Test("a submission records qualities, four frames, the login and the payload")
  func submissionRecords() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let records = VideoRecordStore(fileURL: directory.appending(path: "videos.json"))
    let payloads = PayloadStore(directory: directory.appending(path: "payloads"))

    VideoRecorder.record(
      fetched, for: "2844787557", helperVersion: "1.56.5",
      records: records, payloads: payloads)

    let library = try records.load()
    #expect(library.videos["2844787557"]?.qualities.first?.name == "1080p60")
    #expect(library.videos["2844787557"]?.thumbnailURLs.count == 4)
    #expect(library.videos["2844787557"]?.login == "wheelyf")
    #expect(library.videos["2844787557"]?.payloadHelperVersion == "1.56.5")
    #expect(payloads.payload(for: "2844787557") == fetched.payload)
  }

  /// The moments line is stored even though nothing parses it. That is the
  /// entire reason the payload is kept verbatim.
  @Test("the unparsed parts of the payload survive")
  func unparsedPartsSurvive() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let records = VideoRecordStore(fileURL: directory.appending(path: "videos.json"))
    let payloads = PayloadStore(directory: directory.appending(path: "payloads"))

    VideoRecorder.record(
      fetched, for: "2844787557", helperVersion: "1.56.5",
      records: records, payloads: payloads)

    #expect(payloads.payload(for: "2844787557")?.contains("moments") == true)
  }

  /// A record write must never be able to fail a download. An unusable id is
  /// the cheapest way to force the payload write to throw.
  @Test("a failed payload write still records the facts")
  func payloadFailureIsNotFatal() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let records = VideoRecordStore(fileURL: directory.appending(path: "videos.json"))
    let payloads = PayloadStore(directory: directory.appending(path: "payloads"))

    VideoRecorder.record(
      fetched, for: "../escape", helperVersion: "1.56.5",
      records: records, payloads: payloads)

    // The facts still landed; only the payload did not.
    #expect(try records.load().videos["../escape"]?.login == "wheelyf")
    #expect(payloads.payload(for: "../escape") == nil)
  }

  /// No helper version means no stamp — and an unstamped payload is not
  /// re-parseable later, so it is not written at all rather than written
  /// anonymously.
  @Test("an unknown helper version stores facts but no payload")
  func noVersionMeansNoPayload() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let records = VideoRecordStore(fileURL: directory.appending(path: "videos.json"))
    let payloads = PayloadStore(directory: directory.appending(path: "payloads"))

    VideoRecorder.record(
      fetched, for: "1", helperVersion: nil, records: records, payloads: payloads)

    #expect(try records.load().videos["1"]?.qualities.count == 1)
    #expect(payloads.payload(for: "1") == nil)
  }
}
