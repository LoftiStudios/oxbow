import Testing

@testable import OxbowKit

@Suite("DotNet random")
struct DotNetRandomTests {

  /// Vectors taken from `System.Random(seed).NextDouble()` on .NET 10, the helper's runtime.
  @Test func matchesDotNetForSeedFive() {
    var random = DotNetRandom(seed: 5)
    let draws = (0..<5).map { _ in random.nextDouble() }
    #expect(draws == [
      0.33836984091362443, 0.2844184475412678, 0.2629626417825756, 0.6253758443637638,
      0.46346185284827923,
    ])
  }

  @Test func matchesDotNetForSeedOneThousand() {
    var random = DotNetRandom(seed: 1000)
    let draws = (0..<3).map { _ in random.nextDouble() }
    #expect(draws == [0.15155745910087481, 0.2359429496507826, 0.7560131669770987])
  }
}
