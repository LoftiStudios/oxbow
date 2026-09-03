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

  /// Stored in preferences, so the wire names are load-bearing. Driving the
  /// round trip off `allCases` catches a new case automatically; the literal
  /// strings are what actually catch a rename — a loop alone would round-trip
  /// happily even after one.
  @Test func rawValuesArePersistedAndPinned() {
    for size in ChatSize.allCases {
      #expect(ChatSize(rawValue: size.rawValue) == size)
    }
    #expect(ChatSize.small.rawValue == "small")
    #expect(ChatSize.medium.rawValue == "medium")
    #expect(ChatSize.large.rawValue == "large")
  }
}
