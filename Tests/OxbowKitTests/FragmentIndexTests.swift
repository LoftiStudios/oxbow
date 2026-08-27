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
}
