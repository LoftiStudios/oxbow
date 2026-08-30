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

  /// What a `SIGKILL` mid-write actually leaves: the encoder writes `moov`
  /// last, so a kill during the `mdat` write never gets there at all — there
  /// is no partial `moov` box on disk to find, just an absence.
  @Test func aFileKilledBeforeMoovHasNone() throws {
    var data = FragmentBuilder.box("ftyp", Data(repeating: 0, count: 8))
    data.append(FragmentBuilder.box("mdat", Data(repeating: 0xAB, count: 32)))
    let url = try FragmentBuilder.write(data)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try !FragmentedMP4.hasCompleteMoov(at: url))
  }

  /// The rarer case: the kill lands while `moov` itself is mid-write, so its
  /// header is on disk but its declared size runs past the end of the file.
  /// A header alone is not a usable box.
  @Test func aTornMoovIsNotComplete() throws {
    var data = FragmentBuilder.box("ftyp", Data(repeating: 0, count: 8))
    data.append(FragmentBuilder.box("mdat", Data(repeating: 0xAB, count: 32)))
    let whole = FragmentBuilder.box("moov", Data(repeating: 0, count: 64))
    data.append(whole.prefix(20)) // header + a few bytes, not the full box
    let url = try FragmentBuilder.write(data)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try !FragmentedMP4.hasCompleteMoov(at: url))
  }

  /// The hand-built fixtures above prove the parser reads what it was told to.
  /// This proves it reads what FFmpeg actually writes, which is the claim that
  /// matters. Regenerate with the command in `task-3-report.md` if FFmpeg changes.
  @Test func readsARealFFmpegFragmentedFile() throws {
    let url = try Fixture.url(named: "fragmented-3-frames.mp4")

    let index = try FragmentedMP4.index(of: url)
    let size = try FileManager.default
      .attributesOfItem(atPath: url.path)[.size] as? Int

    #expect(index.frameCount == 3)
    #expect(index.completeBytes == size)
  }

  /// A `largesize` past `Int.max` used to trap inside a bare `Int(...)`
  /// conversion — not catchable by the `try?` at every call site of
  /// `hasCompleteMoov`, so it took the whole process down instead of failing
  /// the one call. Confirms the box now reads as malformed instead.
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

  /// The hand-built fixtures above prove the parser's `moov`-detection logic
  /// against boxes we told it to have. This proves the specific case that
  /// matters for the sidecar and was previously untested against real
  /// output: what a genuinely `SIGKILL`ed FFmpeg audio write actually leaves
  /// on disk. A killed-early write never gets past the `mdat` header — the
  /// muxer writes a placeholder `size == 0` there (spec meaning: "extends to
  /// EOF") and patches it to the real size only when it finalises — so this
  /// exercises the `boxSize == 0` branch in `FragmentedMP4`, which no other
  /// test reaches. The verdict is `false` either way (there is no `moov`,
  /// complete or not), so this is not a live bug — but nothing checked in
  /// previously demonstrated it against a real file.
  ///
  /// Regenerated with (deterministic across repeated runs — the kill lands
  /// before the encoder has written its first frame, well before the
  /// pipeline is warm enough for scheduling jitter to matter):
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

  /// Reading `mvhd` is what lets a resumed composite know whether its chat
  /// render is long enough to seek into. Doing it here rather than with a
  /// subprocess keeps `makeContext` free of process spawning, and we bundle
  /// no `ffprobe` to ask.
  @Test func durationReadsTheMovieHeader() throws {
    let url = try FragmentBuilder.write(
      FragmentBuilder.fileWithDuration(timescale: 1000, duration: 5000))
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try FragmentedMP4.duration(of: url) == .seconds(5))
  }

  /// A 64-bit `mvhd`. Rare in files this size, but the version byte decides
  /// the field widths and reading it with the wrong layout would not fail —
  /// it would return a plausible, wrong number, which is the worst outcome
  /// for a value used to clamp a seek.
  @Test func durationReadsAVersionOneMovieHeader() throws {
    let url = try FragmentBuilder.write(
      FragmentBuilder.fileWithDuration(timescale: 90000, duration: 900_000, version: 1))
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try FragmentedMP4.duration(of: url) == .seconds(10))
  }

  /// No `moov`, no answer — and specifically not zero. A caller that clamps
  /// a seek must be able to tell "the render is this long" from "I could not
  /// find out", because those call for opposite behaviour: clamp, or leave
  /// the seek alone.
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
