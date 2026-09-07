import Foundation
import Testing
@testable import OxbowKit

/// `betterCapacity` exists because of one measured fact: on a network volume
/// `volumeAvailableCapacityForImportantUsage` answers **zero**, not nil.
/// Measured on an SMB share with 8 TB free — importantUsage 0 bytes, plain
/// capacity 8035.90 GB. Zero sails past every `??` fallback, so a NAS
/// destination read as a full disk and its channel was demoted on every
/// sweep, permanently.
@Suite("Volume capacity selection")
struct VolumeSpaceCapacityTests {

  @Test("a network volume reporting zero important-usage uses the plain figure")
  func networkVolumeUsesPlainCapacity() {
    let eightTerabytes: Int64 = 8_035_900_000_000
    #expect(VolumeSpace.betterCapacity(important: 0, plain: eightTerabytes) == eightTerabytes)
  }

  /// The local case must not regress: importantUsage counts purgeable space
  /// and is the larger there, which is the figure this deliberately keeps.
  @Test("a local volume keeps the purgeable-inclusive figure")
  func localVolumeKeepsImportantUsage() {
    #expect(VolumeSpace.betterCapacity(
      important: 125_400_000_000, plain: 57_330_000_000) == 125_400_000_000)
  }

  @Test("either key alone still answers")
  func oneKeyIsEnough() {
    #expect(VolumeSpace.betterCapacity(important: 42, plain: nil) == 42)
    #expect(VolumeSpace.betterCapacity(important: nil, plain: 42) == 42)
  }

  /// Unreadable and empty stay distinct — the distinction whose loss caused
  /// this in the first place.
  @Test("neither key answering is nil, not zero")
  func neitherKeyIsNil() {
    #expect(VolumeSpace.betterCapacity(important: nil, plain: nil) == nil)
  }

  /// A genuinely full local disk still reads as full.
  @Test("a genuinely full volume reads as zero rather than being talked up")
  func fullVolumeStaysFull() {
    #expect(VolumeSpace.betterCapacity(important: 0, plain: 0) == 0)
  }
}
