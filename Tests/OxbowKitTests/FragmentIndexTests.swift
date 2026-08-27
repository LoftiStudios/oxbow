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
