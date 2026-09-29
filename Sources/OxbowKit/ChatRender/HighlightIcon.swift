// The icon paths below are copied verbatim from TwitchDownloader's
// TwitchDownloaderCore/Tools/HighlightIcons.cs (HI:36-43).
// Copyright (c) lay295 and contributors. MIT License.

import CoreGraphics
import Foundation

/// The icons the CLI draws beside sub, gift, bits-badge, watch-streak and charity messages:
/// SVG paths authored in a 72-unit box, filled even-odd (HI:249-282). Drawn here as vectors
/// rather than Skia's 72→25 resample, so they stay sharp at any font size.
enum HighlightIcon: Sendable, CaseIterable {
  case star, crown, gift, ghost, gem, flame, charity

  /// The box every path is authored in (HI:47).
  static let unitSize: Double = 72

  /// In the 72-unit box, y down, as authored.
  var path: CGPath { SVGPath.parse(pathData) }

  private var pathData: String {
    switch self {
    case .star: "m 32.599229,13.144498 c 1.307494,-2.80819 5.494049,-2.80819 6.80154,0 l 5.648628,12.140919 13.52579,1.877494 c 3.00144,0.418654 4.244522,3.893468 2.138363,5.967405 -3.357829,3.309501 -6.715662,6.618992 -10.073491,9.928491 L 53.07148,56.81637 c 0.524928,2.962772 -2.821092,5.162303 -5.545572,3.645496 L 36,54.043603 24.474093,60.461866 C 21.749613,61.975455 18.403591,59.779142 18.92852,56.81637 L 21.359942,43.058807 11.286449,33.130316 c -2.1061588,-2.073937 -0.863074,-5.548751 2.138363,-5.967405 l 13.52579,-1.877494 z"
    case .crown: "m 61.894653,21.663055 v 25.89488 c 0,3.575336 -2.898361,6.47372 -6.473664,6.47372 H 16.57901 c -3.573827,-0.0036 -6.470094,-2.89986 -6.473663,-6.47372 V 21.663055 L 23.052674,31.373635 36,18.426194 c 4.315772,4.315816 8.631553,8.631629 12.947323,12.947441 z"
    case .gift: "m 55.187956,23.24523 h 6.395987 V 42.433089 H 58.38595 V 61.620947 H 13.614042 V 42.433089 H 10.416049 V 23.24523 h 6.395987 v -3.859957 c 0,-8.017328 9.689919,-12.0307888 15.359963,-6.363975 0.418936,0.418935 0.796298,0.879444 1.125692,1.371934 l 2.702305,4.055034 2.702305,-4.055034 a 8.9863623,8.9863139 0 0 1 1.125692,-1.371934 c 5.666845,-5.6668138 15.359963,-1.653353 15.359963,6.363975 z M 23.208023,19.385273 v 3.859957 h 8.301992 l -3.536982,-5.305444 a 2.6031666,2.6031528 0 0 0 -4.76501,1.445487 z m 25.583946,0 v 3.859957 h -8.301991 l 3.536983,-5.305444 a 2.6031666,2.6031528 0 0 1 4.765008,1.442286 z m 6.395987,10.255909 v 6.395951 H 39.19799 v -6.395951 z m -3.197992,25.58381 V 42.433089 H 39.19799 V 55.224992 Z M 32.802003,29.641182 v 6.395951 H 16.812036 v -6.395951 z m 0,12.791907 H 20.010028 v 12.791903 h 12.791975 z"
    case .ghost: "m 54.571425,64.514958 a 4.3531428,4.2396967 0 0 1 -1.273998,-0.86096 l -1.203426,-1.172067 a 7.0051428,6.822584 0 0 0 -9.90229,0 c -3.417139,3.328092 -8.962569,3.328092 -12.383427,0 l -0.159707,-0.155553 a 7.1871427,6.9998405 0 0 0 -9.854005,-0.28216 l -1.894286,1.635103 a 4.9362858,4.8076423 0 0 1 -3.276,1.215474 H 10 V 32.337399 a 26.000001,25.322423 0 0 1 52,0 v 32.557396 h -5.627146 c -0.627714,0 -1.240569,-0.133847 -1.801429,-0.379837 z M 35.999996,14.249955 A 18.571428,18.087444 0 0 0 17.428572,32.337399 v 22.515245 a 14.619428,14.238435 0 0 1 17.471998,2.358609 l 0.163448,0.155554 c 0.516285,0.50645 1.355715,0.50645 1.875712,0 a 14.437428,14.061179 0 0 1 17.631712,-2.11623 V 32.337399 A 18.571428,18.087444 0 0 0 35.999996,14.249955 Z M 24.857142,35.954887 a 3.7142855,3.6174889 0 1 1 7.42857,0 3.7142855,3.6174889 0 0 1 -7.42857,0 z m 18.571432,-3.617488 a 3.7142859,3.6174892 0 1 0 0,7.234978 3.7142859,3.6174892 0 0 0 0,-7.234978 z"
    case .gem: "M 14.242705,42.37453 36,11.292679 57.757295,42.37453 36,61.023641 Z M 22.566425,41.323963 36,22.13092 49.433577,41.317747 46.79162,43.580506 36,39.266345 25.205273,43.586723 22.566425,41.320854 Z"
    case .flame: "M 38.84325,21.169078 33.156748,14.060989 21.215093,27.992844 a 21.267516,21.267402 0 0 0 -5.11785,13.846557 c 0,9.752298 7.961102,17.713358 17.713453,17.713358 H 38.50206 A 17.400696,17.400602 0 0 0 55.902755,42.152157 c 0,-5.288419 -1.848114,-10.406242 -5.231581,-14.500501 L 41.686501,16.904225 Z m -13.306415,10.519973 7.619913,-9.098354 5.686502,7.108089 2.843251,-4.264854 4.606066,5.885497 a 16.945776,16.945684 0 0 1 3.923686,10.832728 c 0,5.91393 -4.407039,10.804296 -10.121973,11.600401 1.02357,-1.336321 1.592221,-2.985397 1.592221,-4.719771 0,-1.478483 -0.511786,-2.900101 -1.421626,-4.065827 l -4.264877,-5.316851 -4.264876,5.316851 c -0.90984,1.137294 -1.421625,2.587344 -1.421625,4.065827 0,1.705941 0.56865,3.355018 1.535355,4.662906 A 12.026952,12.026887 0 0 1 21.783744,41.839401 c 0,-3.72464 1.336328,-7.335548 3.753091,-10.15035 z"
    case .charity: "M 14.211579,29.774743 23.549474,11.09897 H 48.450526 L 57.788421,29.774743 47.345541,42.829108 60.901052,60.90103 H 39.112633 L 36,57.010242 32.887368,60.90103 h -21.78842 l 13.55551,-18.071922 z m 13.185107,-12.450515 -3.112631,6.225256 h 23.43189 l -3.112632,-6.225256 z m 2.378051,12.450515 2.334473,3.112628 -3.598202,4.796559 -6.32798,-7.909187 z m 10.20943,22.255295 2.119703,2.645734 h 6.346656 l -5.12028,-6.829109 -3.342966,4.180262 z  M 23.549474,54.675772 42.225261,29.774743 h 7.59171 L 29.89613,54.675772 Z"
    }
  }
}

/// Just enough of SVG path syntax for the icons above: M, L, H, V, C, A and Z, absolute and
/// relative, with implicit repeats. Not a general parser.
enum SVGPath {
  static func parse(_ data: String) -> CGPath {
    var scanner = Scanner(data)
    let path = CGMutablePath()
    var current = CGPoint.zero
    var start = CGPoint.zero
    var command: Character = "M"

    while let next = scanner.peekCommandOrNumber() {
      if case .command(let c) = next {
        scanner.advance()
        command = c
        if c == "Z" || c == "z" {
          path.closeSubpath()
          current = start
          continue
        }
      }
      let relative = command.isLowercase
      func point() -> CGPoint? {
        guard let x = scanner.number(), let y = scanner.number() else { return nil }
        return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
      }
      switch command.uppercased() {
      case "M":
        guard let p = point() else { return path }
        path.move(to: p)
        current = p
        start = p
        // Further pairs after a move are lines (SVG 1.1 §8.3.2).
        command = relative ? "l" : "L"
      case "L":
        guard let p = point() else { return path }
        path.addLine(to: p)
        current = p
      case "H":
        guard let x = scanner.number() else { return path }
        current = CGPoint(x: relative ? current.x + x : x, y: current.y)
        path.addLine(to: current)
      case "V":
        guard let y = scanner.number() else { return path }
        current = CGPoint(x: current.x, y: relative ? current.y + y : y)
        path.addLine(to: current)
      case "C":
        guard let c1 = point(), let c2 = point(), let p = point() else { return path }
        path.addCurve(to: p, control1: c1, control2: c2)
        current = p
      case "A":
        guard let rx = scanner.number(), let ry = scanner.number(),
              let rotation = scanner.number(), let large = scanner.number(),
              let sweep = scanner.number(), let p = point()
        else { return path }
        addArc(to: path, from: current, to: p, radii: (rx, ry), rotation: rotation,
               largeArc: large != 0, sweep: sweep != 0)
        current = p
      default:
        return path
      }
    }
    return path
  }

  /// SVG's endpoint arc as cubic Béziers, by the conversion in SVG 1.1 appendix F.6.
  private static func addArc(
    to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, radii: (Double, Double),
    rotation: Double, largeArc: Bool, sweep: Bool)
  {
    var rx = abs(radii.0)
    var ry = abs(radii.1)
    guard rx > 0, ry > 0, p0 != p1 else {
      path.addLine(to: p1)
      return
    }
    let phi = rotation * .pi / 180
    let cosPhi = cos(phi)
    let sinPhi = sin(phi)
    let dx = (p0.x - p1.x) / 2
    let dy = (p0.y - p1.y) / 2
    let x1 = cosPhi * dx + sinPhi * dy
    let y1 = -sinPhi * dx + cosPhi * dy
    let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lambda > 1 {
      rx *= lambda.squareRoot()
      ry *= lambda.squareRoot()
    }
    let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
    var factor = (max(numerator, 0) / denominator).squareRoot()
    if largeArc == sweep { factor = -factor }
    let cx1 = factor * rx * y1 / ry
    let cy1 = -factor * ry * x1 / rx
    let cx = cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2
    let cy = sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2

    func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
      let sign: Double = ux * vy - uy * vx < 0 ? -1 : 1
      let dot = (ux * vx + uy * vy) / ((ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot())
      return sign * acos(min(max(dot, -1), 1))
    }
    let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
    var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
    if !sweep, delta > 0 { delta -= 2 * .pi }
    if sweep, delta < 0 { delta += 2 * .pi }

    // One cubic per quarter turn or less.
    let segments = max(Int((abs(delta) / (.pi / 2)).rounded(.up)), 1)
    let step = delta / Double(segments)
    let k = 4.0 / 3.0 * tan(step / 4)
    func onEllipse(_ t: Double) -> (CGPoint, CGPoint) {
      let x = rx * cos(t)
      let y = ry * sin(t)
      let point = CGPoint(x: cx + cosPhi * x - sinPhi * y, y: cy + sinPhi * x + cosPhi * y)
      let tx = -rx * sin(t)
      let ty = ry * cos(t)
      return (point, CGPoint(x: cosPhi * tx - sinPhi * ty, y: sinPhi * tx + cosPhi * ty))
    }
    var t = theta1
    for _ in 0..<segments {
      let (start, startTangent) = onEllipse(t)
      let (end, endTangent) = onEllipse(t + step)
      path.addCurve(
        to: end,
        control1: CGPoint(x: start.x + k * startTangent.x, y: start.y + k * startTangent.y),
        control2: CGPoint(x: end.x - k * endTangent.x, y: end.y - k * endTangent.y))
      t += step
    }
  }

  private enum Token { case command(Character), number }

  private struct Scanner {
    private let characters: [Character]
    private var index = 0

    init(_ text: String) { characters = Array(text) }

    private mutating func skipSeparators() {
      while index < characters.count, characters[index] == " " || characters[index] == "," {
        index += 1
      }
    }

    mutating func peekCommandOrNumber() -> Token? {
      skipSeparators()
      guard index < characters.count else { return nil }
      let c = characters[index]
      return c.isLetter && c != "e" && c != "E" ? .command(c) : .number
    }

    mutating func advance() { index += 1 }

    mutating func number() -> Double? {
      skipSeparators()
      let start = index
      if index < characters.count, characters[index] == "-" || characters[index] == "+" { index += 1 }
      var seenDot = false
      while index < characters.count {
        let c = characters[index]
        if c.isNumber { index += 1 }
        else if c == ".", !seenDot { seenDot = true; index += 1 }
        else if c == "e" || c == "E" {
          index += 1
          if index < characters.count, characters[index] == "-" || characters[index] == "+" { index += 1 }
        }
        else { break }
      }
      return Double(String(characters[start..<index]))
    }
  }
}
