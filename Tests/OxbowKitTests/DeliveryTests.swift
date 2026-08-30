import Foundation
import Testing
@testable import OxbowKit

@Suite("Delivery")
struct DeliveryTests {

  private let file = URL(filePath: "/workspace/step/out.mp4")
  private let destination = URL(filePath: "/downloads/out.mp4")

  /// Records what was asked of the filesystem, so a test can assert on where
  /// the file actually went rather than on the return value alone.
  private final class Moves {
    var attempts: [URL] = []
  }

  @Test func movesStraightToAFreeDestination() throws {
    let moves = Moves()

    let landed = try Delivery.moveWithoutReplacing(
      file, to: destination,
      exists: { _ in false },
      move: { _, to in moves.attempts.append(to) })

    #expect(landed == destination)
    #expect(moves.attempts == [destination])
  }

  @Test func stepsAsideRatherThanOverwritingWhatIsAlreadyThere() throws {
    let moves = Moves()

    let landed = try Delivery.moveWithoutReplacing(
      file, to: destination,
      exists: { $0 == self.destination },
      move: { _, to in moves.attempts.append(to) })

    #expect(landed == URL(filePath: "/downloads/out (2).mp4"))
    #expect(moves.attempts == [URL(filePath: "/downloads/out (2).mp4")])
  }

  /// The gap between choosing a free name and moving into it belongs to
  /// whatever else is writing to the user's Downloads folder. Losing that
  /// race must cost a second attempt, not a failed job after a two-hour
  /// download.
  @Test func triesAgainWhenTheChosenNameIsTakenBetweenTheCheckAndTheMove() throws {
    let moves = Moves()
    let contested = URL(filePath: "/downloads/out (2).mp4")

    let landed = try Delivery.moveWithoutReplacing(
      file, to: destination,
      // `contested` becomes taken only once something has tried to move
      // into it — which is exactly the ordering the race has: free when
      // chosen, occupied by the time the move lands.
      exists: { $0 == self.destination || moves.attempts.contains($0) },
      move: { _, to in
        moves.attempts.append(to)
        if to == contested {
          throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
        }
      })

    #expect(landed == URL(filePath: "/downloads/out (3).mp4"))
    #expect(moves.attempts == [contested, URL(filePath: "/downloads/out (3).mp4")])
  }

  /// A full disk or a read-only folder must surface as a move failure, not
  /// spin through candidate names inventing files nobody can write either.
  @Test func rethrowsAFailureThatIsNotACollision() {
    let moves = Moves()
    let outOfSpace = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)

    #expect(throws: (any Error).self) {
      try Delivery.moveWithoutReplacing(
        file, to: destination,
        exists: { _ in false },
        move: { _, _ in
          moves.attempts.append(self.destination)
          throw outOfSpace
        })
    }
    #expect(moves.attempts.count == 1, "it must not retry a failure that is not a collision")
  }
}
