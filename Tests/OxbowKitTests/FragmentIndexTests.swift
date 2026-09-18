import Foundation
import Testing
@testable import OxbowKit

@Suite("Fragmented MP4 index")
struct FragmentIndexTests {

  @Test func countsSamplesAcrossCompleteFragments() throws {
    let data = FragmentBuilder.fragmentedFile([10, 20, 30])
    let url = try FragmentBuilder.write(data)
    defer { try? FileManager.default.removeItem(at: url) }

    let index = try FragmentedMP4.index(of: url)

    #expect(index.frameCount == 60)
    #expect(index.completeBytes == data.count)
  }

  /// A crash leaves a partial box. Everything before it is still good.
  @Test func stopsAtATornBox() throws {
    let whole = FragmentBuilder.fragmentedFile([10, 20])
    let torn = whole.prefix(whole.count - 12)
    let url = try FragmentBuilder.write(Data(torn))
    defer { try? FileManager.default.removeItem(at: url) }

    let index = try FragmentedMP4.index(of: url)

    #expect(index.frameCount == 10)
    #expect(index.completeBytes < torn.count)
  }

  /// A `moof` whose `mdat` never arrived describes frames that are not
  /// there. It must not be counted, and the cut goes before it.
  @Test func ignoresAMoofWithNoMdat() throws {
    var data = FragmentBuilder.fragmentedFile([10])
    let afterFirstFragment = data.count
    data.append(FragmentBuilder.moof(samples: 99))
    let url = try FragmentBuilder.write(data)
    defer { try? FileManager.default.removeItem(at: url) }

    let index = try FragmentedMP4.index(of: url)

    #expect(index.frameCount == 10)
    #expect(index.completeBytes == afterFirstFragment)
  }

  @Test func handlesAFileWithNoCompleteFragment() throws {
    let url = try FragmentBuilder.write(FragmentBuilder.fragmentedFile([]))
    defer { try? FileManager.default.removeItem(at: url) }

    let index = try FragmentedMP4.index(of: url)

    #expect(index.frameCount == 0)
  }

  @Test func repairTruncatesToTheCompletePrefix() throws {
    let whole = FragmentBuilder.fragmentedFile([10, 20], trailingGarbage: 40)
    let url = try FragmentBuilder.write(whole)
    defer { try? FileManager.default.removeItem(at: url) }

    let index = try FragmentedMP4.repair(url)
    let size = try FileManager.default
      .attributesOfItem(atPath: url.path)[.size] as? Int

    #expect(index.frameCount == 30)
    #expect(size == index.completeBytes)
  }

  /// A finalised, ordinary (non-fragmented) MP4: `ftyp`, `mdat`, then `moov`
  /// written last — the layout a stream copy without `+faststart` produces.
  @Test func recognisesACompleteTopLevelMoov() throws {
    var data = FragmentBuilder.box("ftyp", Data(repeating: 0, count: 8))
    data.append(FragmentBuilder.box("mdat", Data(repeating: 0xAB, count: 32)))
    data.append(FragmentBuilder.box("moov", Data(repeating: 0, count: 16)))
    let url = try FragmentBuilder.write(data)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try FragmentedMP4.hasCompleteMoov(at: url))
  }

  /// A kill during `mdat` leaves no trailing `moov` at all.
  @Test func aFileKilledBeforeMoovHasNone() throws {
    var data = FragmentBuilder.box("ftyp", Data(repeating: 0, count: 8))
    data.append(FragmentBuilder.box("mdat", Data(repeating: 0xAB, count: 32)))
    let url = try FragmentBuilder.write(data)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try !FragmentedMP4.hasCompleteMoov(at: url))
  }

  /// A partial `moov` header is not a complete box.
  @Test func aTornMoovIsNotComplete() throws {
    var data = FragmentBuilder.box("ftyp", Data(repeating: 0, count: 8))
    data.append(FragmentBuilder.box("mdat", Data(repeating: 0xAB, count: 32)))
    let whole = FragmentBuilder.box("moov", Data(repeating: 0, count: 64))
    data.append(whole.prefix(20)) // header + a few bytes, not the full box
    let url = try FragmentBuilder.write(data)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try !FragmentedMP4.hasCompleteMoov(at: url))
  }

  /// Real FFmpeg fixture complements synthetic boxes; regeneration is recorded in
  /// `task-3-report.md`.
  @Test func readsARealFFmpegFragmentedFile() throws {
    let url = try Fixture.url(named: "fragmented-3-frames.mp4")

    let index = try FragmentedMP4.index(of: url)
    let size = try FileManager.default
      .attributesOfItem(atPath: url.path)[.size] as? Int

    #expect(index.frameCount == 3)
    #expect(index.completeBytes == size)
  }

  /// Oversized `largesize` must fail parsing instead of trapping during Int conversion.
  @Test func aLargesizeBeyondIntMaxDoesNotTrap() throws {
    var data = FragmentBuilder.box("ftyp", Data(repeating: 0, count: 8))
    data.append(FragmentBuilder.oversizedBox("moov"))
    let url = try FragmentBuilder.write(data)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try !FragmentedMP4.hasCompleteMoov(at: url))
  }

  /// Same trap, exercised through `index(of:)` — the half that pieces
  /// (rather than the sidecar) are actually checked with.
  @Test func indexToleratesALargesizeBeyondIntMax() throws {
    var data = FragmentBuilder.box("ftyp", Data(repeating: 0, count: 8))
    let beforeTheOversizedBox = data.count
    data.append(FragmentBuilder.oversizedBox("mdat"))
    let url = try FragmentBuilder.write(data)
    defer { try? FileManager.default.removeItem(at: url) }

    let index = try FragmentedMP4.index(of: url)

    #expect(index.frameCount == 0)
    #expect(index.completeBytes == beforeTheOversizedBox)
  }

  /// Real killed audio fixture: `mdat` retains its size-zero (to-EOF) placeholder
  /// and no trailing `moov` exists. Regenerate with:
  /// ```
  /// build/ffmpeg/ffmpeg -nostdin -y -hide_banner -loglevel error \
  ///   -f s16le -ar 44100 -ac 1 -i /dev/zero -t 60 -c:a aac -b:a 64k \
  ///   sigkilled-audio-sidecar.m4a &
  /// PID=$!; sleep 0.02; kill -KILL $PID
  /// ```
  @Test func aRealSigkilledAudioWriteHasNoMoov() throws {
    let url = try Fixture.url(named: "sigkilled-audio-sidecar.m4a")

    #expect(try !FragmentedMP4.hasCompleteMoov(at: url))
  }

  // MARK: - Duration

  /// Container duration supplies chat seek clamping without a bundled ffprobe.
  @Test func durationReadsTheMovieHeader() throws {
    let url = try FragmentBuilder.write(
      FragmentBuilder.fileWithDuration(timescale: 1000, duration: 5000))
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try FragmentedMP4.duration(of: url) == .seconds(5))
  }

  /// Pin version-1 field widths; the wrong layout can return a plausible duration.
  @Test func durationReadsAVersionOneMovieHeader() throws {
    let url = try FragmentBuilder.write(
      FragmentBuilder.fileWithDuration(timescale: 90000, duration: 900_000, version: 1))
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try FragmentedMP4.duration(of: url) == .seconds(10))
  }

  /// Unknown duration must be nil, not zero, to avoid clamping all seeks to the start.
  @Test func durationIsNilWithoutAMovieHeader() throws {
    let url = try FragmentBuilder.write(FragmentBuilder.box("ftyp", Data(repeating: 0, count: 8)))
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try FragmentedMP4.duration(of: url) == nil)
  }

  /// A `moov` whose `mvhd` is truncated mid-field. Same reasoning as above:
  /// unreadable must be `nil`, never a partial number.
  @Test func durationIsNilWhenTheMovieHeaderIsTruncated() throws {
    var data = FragmentBuilder.box("ftyp", Data(repeating: 0, count: 8))
    data.append(FragmentBuilder.box("moov", FragmentBuilder.box("mvhd", Data([0, 0, 0, 0, 1, 2]))))
    let url = try FragmentBuilder.write(data)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try FragmentedMP4.duration(of: url) == nil)
  }

  /// A zero timescale would divide by zero. Malformed rather than
  /// impossible, and the answer is the same as any other unreadable header.
  @Test func durationIsNilWhenTheTimescaleIsZero() throws {
    let url = try FragmentBuilder.write(
      FragmentBuilder.fileWithDuration(timescale: 0, duration: 5000))
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try FragmentedMP4.duration(of: url) == nil)
  }
}
