import Foundation
import Testing
@testable import OxbowKit

@Suite("Volume space")
struct VolumeSpaceTests {

  private let workspace = URL(filePath: "/Users/x/Library/Caches/Oxbow")
  private let internalDestination = URL(filePath: "/Users/x/Movies")
  private let externalDestination = URL(filePath: "/Volumes/Scratch/Videos")

  /// Two volumes, keyed by mount point, so a test can give each a different
  /// amount without caring which path maps to which.
  private func probe(_ free: [String: Int64]) -> VolumeSpace {
    VolumeSpace(
      availableBytes: { free[Self.root(of: $0).path] },
      volumeRoot: { Self.root(of: $0) },
      volumeName: { Self.root(of: $0).path == "/" ? "Macintosh HD" : "Scratch" })
  }

  private static func root(of url: URL) -> URL {
    url.path.hasPrefix("/Volumes/Scratch")
      ? URL(filePath: "/Volumes/Scratch")
      : URL(filePath: "/")
  }

  /// One volume: the workspace's peak is the whole answer, because a
  /// same-volume `moveItem` is a rename and the delivered file costs nothing
  /// on top of the total that already contains it.
  @Test func oneVolumeIsCheckedAgainstTheWorkspaceTotal() throws {
    let space = probe(["/": 30_000_000_000])
    let found = try #require(space.shortfall(
      needingWorkspace: 49_000_000_000,
      delivered: 15_000_000_000,
      workspace: workspace,
      destination: internalDestination))

    #expect(found.needed == 49_000_000_000, "the delivered file must not be counted twice")
    #expect(found.available == 30_000_000_000)
    #expect(found.volumeName == "Macintosh HD")
  }

  /// Enough room is `nil`, not a zero-valued shortfall: the callers render
  /// presence, and an always-present value would make both of them ask a
  /// second question to find out whether the first one meant anything.
  @Test func enoughRoomIsNoShortfall() {
    let space = probe(["/": 200_000_000_000])
    #expect(space.shortfall(
      needingWorkspace: 49_000_000_000,
      delivered: 15_000_000_000,
      workspace: workspace,
      destination: internalDestination) == nil)
  }

  /// Across volumes the peaks are independent: the workspace carries the
  /// transient set and the destination carries one delivered file. Summing
  /// them would produce a number describing neither volume.
  @Test func acrossVolumesTheDestinationIsCheckedAgainstTheDeliveredFileAlone() throws {
    let space = probe(["/": 200_000_000_000, "/Volumes/Scratch": 5_000_000_000])
    let found = try #require(space.shortfall(
      needingWorkspace: 49_000_000_000,
      delivered: 15_000_000_000,
      workspace: workspace,
      destination: externalDestination))

    #expect(found.volumeName == "Scratch")
    #expect(found.needed == 15_000_000_000, "the destination never holds the source or intermediate")
  }

  /// A roomy external drive does not excuse a full boot volume. The workspace
  /// is where the work happens whatever the user chose as a destination.
  @Test func aRoomyDestinationDoesNotHideAFullWorkspaceVolume() throws {
    let space = probe(["/": 5_000_000_000, "/Volumes/Scratch": 900_000_000_000])
    let found = try #require(space.shortfall(
      needingWorkspace: 49_000_000_000,
      delivered: 15_000_000_000,
      workspace: workspace,
      destination: externalDestination))

    #expect(found.volumeName == "Macintosh HD")
  }

  /// Both volumes short reports the workspace, deterministically. Which one is
  /// named barely matters — the user has to clear one of them either way — but
  /// a warning that names a different volume on each evaluation would read as
  /// a bug.
  @Test func bothVolumesShortReportsTheWorkspaceDeterministically() throws {
    let space = probe(["/": 1_000_000, "/Volumes/Scratch": 1_000_000])
    let found = try #require(space.shortfall(
      needingWorkspace: 49_000_000_000,
      delivered: 15_000_000_000,
      workspace: workspace,
      destination: externalDestination))

    #expect(found.volumeName == "Macintosh HD")
  }

  /// An unreadable volume produces no warning rather than a false one.
  ///
  /// This is the load-bearing case for trust. A warning invented from a failed
  /// probe is one the user cannot act on, and it would fire on exactly the
  /// unusual setups — network shares, odd mounts — where it is least likely to
  /// be right.
  @Test func anUnreadableVolumeProducesNoWarning() {
    let space = VolumeSpace(
      availableBytes: { _ in nil },
      volumeRoot: { _ in nil },
      volumeName: { _ in nil })

    #expect(space.shortfall(
      needingWorkspace: 49_000_000_000,
      delivered: 15_000_000_000,
      workspace: workspace,
      destination: externalDestination) == nil)
  }

  /// A readable mount point whose capacity will not answer is the same case,
  /// and is reachable separately: `volumeRoot` succeeding tells you nothing
  /// about whether `availableBytes` will.
  @Test func aVolumeWhoseCapacityIsUnreadableProducesNoWarning() {
    let space = VolumeSpace(
      availableBytes: { _ in nil },
      volumeRoot: { _ in URL(filePath: "/") },
      volumeName: { _ in "Macintosh HD" })

    #expect(space.shortfall(
      needingWorkspace: 49_000_000_000,
      delivered: 15_000_000_000,
      workspace: workspace,
      destination: internalDestination) == nil)
  }

  /// The live probe against a path that certainly exists. Asserts only that it
  /// reads something plausible — the figure itself is the machine's.
  @Test func theLiveProbeReadsTheBootVolume() throws {
    let temporary = URL(filePath: NSTemporaryDirectory())
    let bytes = try #require(VolumeSpace.live.availableBytes(temporary))

    #expect(bytes > 0)
    #expect(VolumeSpace.live.volumeRoot(temporary) != nil)
    #expect(VolumeSpace.live.volumeName(temporary) != nil)
  }

  /// The workspace directory does not exist on a first launch, and the intake
  /// asks about it anyway. `resourceValues` on a missing path throws rather
  /// than answering about the volume it would live on, so the live probe has
  /// to walk up to something real first.
  @Test func theLiveProbeAnswersForAPathThatDoesNotExistYet() throws {
    let missing = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-\(UUID().uuidString)/nested/deeper")

    #expect(!FileManager.default.fileExists(atPath: missing.path), "precondition")
    let bytes = try #require(VolumeSpace.live.availableBytes(missing))
    #expect(bytes > 0)
  }
}
