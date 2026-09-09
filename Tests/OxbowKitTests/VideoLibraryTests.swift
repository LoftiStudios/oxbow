import Foundation
import Testing
@testable import OxbowKit

@Suite("Video library")
struct VideoLibraryTests {

  private func record(_ id: String, login: String = "wheelyf") -> VideoRecord {
    VideoRecord(id: id, login: login, title: "t\(id)",
                thumbnailURLs: [URL(string: "https://cdn/\(id).jpg")!])
  }

  @Test("recording a video twice merges rather than replaces")
  func recordMerges() {
    var library = VideoLibrary()
    library.record(record("1"))
    library.record(VideoRecord(id: "1", categoryName: "ELDEN RING"))

    #expect(library.videos["1"]?.title == "t1")
    #expect(library.videos["1"]?.categoryName == "ELDEN RING")
  }

  /// `seen` stops being stored and becomes derived (`channel-history.md`
  /// §3.1): state is not `new` and not `failed`.
  @Test("seen is derived as everything but new and failed")
  func seenIsDerived() {
    var library = VideoLibrary()
    for (id, state) in [
      ("1", WatchState.new), ("2", .skipped), ("3", .queued),
      ("4", .downloaded), ("5", .ignored), ("6", .failed),
    ] {
      library.record(record(id))
      library.setState(state, for: id)
    }

    #expect(library.seenIDs(forLogin: "wheelyf") == ["2", "3", "4", "5"])
  }

  @Test("seen only counts the channel asked for")
  func seenIsPerChannel() {
    var library = VideoLibrary()
    library.record(record("1", login: "wheelyf"))
    library.setState(.downloaded, for: "1")
    library.record(record("2", login: "avabamby"))
    library.setState(.downloaded, for: "2")

    #expect(library.seenIDs(forLogin: "wheelyf") == ["1"])
  }

  /// §3.6: removing a watch drops rows that were only ever "seen on Twitch",
  /// and keeps rows for videos actually downloaded — those are what Get Info
  /// exists to render.
  @Test("removing a watch keeps downloaded rows and drops the rest")
  func removeWatchKeepsWhatYouHave() {
    var library = VideoLibrary()
    library.record(record("1"))
    library.setState(.new, for: "1")

    var downloaded = record("2")
    downloaded.deliveredPath = "/Users/x/Downloads/two.mp4"
    library.record(downloaded)
    library.setState(.downloaded, for: "2")

    library.record(record("3"))
    library.setState(.queued, for: "3")

    library.removeWatch(login: "wheelyf", keepingVideosWithJobs: ["3"])

    #expect(library.videos.keys.sorted() == ["2", "3"])
    #expect(library.watchStates.isEmpty)
  }

  @Test("removing a watch leaves another channel alone")
  func removeWatchIsScoped() {
    var library = VideoLibrary()
    library.record(record("1", login: "wheelyf"))
    library.setState(.new, for: "1")
    library.record(record("2", login: "avabamby"))
    library.setState(.new, for: "2")

    library.removeWatch(login: "wheelyf", keepingVideosWithJobs: [])

    #expect(library.videos.keys.sorted() == ["2"])
    #expect(library.watchStates["2"] == .new)
  }

  /// The input to the image purge: every URL any surviving row still names.
  @Test("referenced images cover every surviving row")
  func referencedImages() {
    var library = VideoLibrary()
    library.record(record("1"))
    library.record(record("2"))

    #expect(library.referencedImageURLs() == [
      URL(string: "https://cdn/1.jpg")!, URL(string: "https://cdn/2.jpg")!,
    ])
  }

  @Test("a library round-trips through JSON")
  func codableRoundTrip() throws {
    var library = VideoLibrary()
    library.record(record("1"))
    library.setState(.downloaded, for: "1")

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let data = try encoder.encode(library)
    #expect(try decoder.decode(VideoLibrary.self, from: data) == library)
  }
}
