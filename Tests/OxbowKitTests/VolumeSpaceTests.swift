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

  /// Same-volume delivery is a rename, so workspace peak already includes its cost.
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

  /// No shortfall is nil, not a zero-valued warning.
  @Test func enoughRoomIsNoShortfall() {
    let space = probe(["/": 200_000_000_000])
    #expect(space.shortfall(
      needingWorkspace: 49_000_000_000,
      delivered: 15_000_000_000,
      workspace: workspace,
      destination: internalDestination) == nil)
  }

  /// Check workspace peak and destination output independently across volumes.
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

  /// When both are short, report workspace deterministically.
  @Test func bothVolumesShortReportsTheWorkspaceDeterministically() throws {
    let space = probe(["/": 1_000_000, "/Volumes/Scratch": 1_000_000])
    let found = try #require(space.shortfall(
      needingWorkspace: 49_000_000_000,
      delivered: 15_000_000_000,
      workspace: workspace,
      destination: externalDestination))

    #expect(found.volumeName == "Macintosh HD")
  }

  /// Failed probes produce no invented shortfall.
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

  /// A readable mount root does not guarantee readable capacity.
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

  /// First-launch workspace may not exist; probe an existing ancestor.
  @Test func theLiveProbeAnswersForAPathThatDoesNotExistYet() throws {
    let missing = URL(filePath: NSTemporaryDirectory())
      .appending(path: "oxbow-\(UUID().uuidString)/nested/deeper")

    #expect(!FileManager.default.fileExists(atPath: missing.path), "precondition")
    let bytes = try #require(VolumeSpace.live.availableBytes(missing))
    #expect(bytes > 0)
  }
}
