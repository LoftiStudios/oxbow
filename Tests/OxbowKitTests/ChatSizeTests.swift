import Testing
@testable import OxbowKit

@Suite("Chat size")
struct ChatSizeTests {

  @Test func defaultsToMedium() {
    #expect(ChatSize.default == .medium)
  }

  @Test func offersExactlyThreeSizesSmallestFirst() {
    #expect(ChatSize.allCases == [.small, .medium, .large])
  }

  /// Literal wire names catch renames; round-tripping all cases alone would not.
  @Test func rawValuesArePersistedAndPinned() {
    for size in ChatSize.allCases {
      #expect(ChatSize(rawValue: size.rawValue) == size)
    }
    #expect(ChatSize.small.rawValue == "small")
    #expect(ChatSize.medium.rawValue == "medium")
    #expect(ChatSize.large.rawValue == "large")
  }
}
