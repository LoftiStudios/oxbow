/// .NET's legacy seeded `System.Random` (Knuth's subtractive generator), reproduced draw for
/// draw. The CLI's jitter fallback seeds one with the comment count, so matching its output
/// means matching this sequence exactly.
struct DotNetRandom {
  private static let big = Int32.max
  private static let seedBase: Int32 = 161_803_398

  private var seeds = [Int32](repeating: 0, count: 56)
  private var next = 0
  private var nextPrime = 21

  init(seed: Int32) {
    let subtraction = seed == .min ? Int32.max : abs(seed)
    var mj = Self.seedBase &- subtraction
    seeds[55] = mj
    var mk: Int32 = 1
    var ii = 0
    for _ in 1..<55 {
      ii += 21
      if ii >= 55 { ii -= 55 }
      seeds[ii] = mk
      mk = mj &- mk
      if mk < 0 { mk &+= Self.big }
      mj = seeds[ii]
    }
    for _ in 1..<5 {
      for i in 1..<56 {
        var n = i + 30
        if n >= 55 { n -= 55 }
        seeds[i] = seeds[i] &- seeds[1 + n]
        if seeds[i] < 0 { seeds[i] &+= Self.big }
      }
    }
  }

  mutating func nextDouble() -> Double {
    next += 1
    if next >= 56 { next = 1 }
    nextPrime += 1
    if nextPrime >= 56 { nextPrime = 1 }
    var result = seeds[next] &- seeds[nextPrime]
    if result == Self.big { result -= 1 }
    if result < 0 { result &+= Self.big }
    seeds[next] = result
    return Double(result) * (1.0 / Double(Self.big))
  }
}
