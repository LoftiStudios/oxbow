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
}
