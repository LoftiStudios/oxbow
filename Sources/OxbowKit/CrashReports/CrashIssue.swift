import Foundation

/// A prefilled "new issue" link for a crash. Opening it sends nothing: the
/// user reads the report in GitHub's own form, adds what they were doing, and
/// submits it or doesn't.
public enum CrashIssue {

  public static let defaultRepository = URL(string: "https://github.com/LoftiStudios/oxbow")!

  /// GitHub answers 414 to a URL much past 8 KB. Frames are dropped from the
  /// outermost end until the link fits, since the innermost ones say the most.
  public static let maximumURLLength = 7_500

  public static func url(
    for report: CrashReport,
    repository: URL = defaultRepository,
    maximumLength: Int = maximumURLLength
  ) -> URL {
    var frameCount = report.frames.count
    while true {
      let url = link(report, repository: repository, frameCount: frameCount)
      if url.absoluteString.count <= maximumLength || frameCount == 0 { return url }
      frameCount -= 1
    }
  }

  public static func title(for report: CrashReport) -> String {
    "Crash in Oxbow \(report.appVersion): \(report.summary)"
  }

  public static func body(for report: CrashReport, frameCount: Int? = nil) -> String {
    let shown = report.frames.prefix(frameCount ?? report.frames.count)
    let nameWidth = shown.map(\.binaryName.count).max() ?? 0
    let trace = shown.enumerated().map { index, frame in
      // At least one space after the number, so frame 100 does not run into
      // the name. scripts/symbolicate-crash.py splits on it.
      let number = String(index).padding(toLength: 3, withPad: " ", startingAt: 0)
        + (index >= 100 ? " " : "")
      let name = frame.binaryName.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
      return "\(number)\(name)  + \(frame.offset)"
    }
    let omitted = report.frames.count - shown.count

    var lines = [
      "**What were you doing when Oxbow quit?**",
      "",
      "",
      "",
      "---",
      "",
      "Oxbow \(report.appVersion) (\(report.appBuild)) · \(report.osVersion)"
        + (report.deviceType.map { " · \($0)" } ?? ""),
      "",
      "**\(report.summary)**" + (report.terminationReason.map { ": \($0)" } ?? ""),
    ]
    if let message = report.exceptionMessage {
      lines += ["", "> \(message)"]
    }
    lines += ["", "Crashed thread:", "```"] + trace
    if omitted > 0 {
      lines.append("… \(omitted) more frames")
    }
    lines.append("```")

    // The dSYM is matched by UUID, so the link has to carry Oxbow's.
    let ownUUIDs = Set(report.frames.filter { $0.binaryName == "Oxbow" }.map(\.binaryUUID))
    if let uuid = ownUUIDs.sorted().first {
      lines += ["", "Oxbow binary: `\(uuid)`"]
    }
    lines += ["", "<sub>Filled in by Oxbow from the crash report macOS kept. Nothing was sent automatically.</sub>"]
    return lines.joined(separator: "\n")
  }

  private static func link(_ report: CrashReport, repository: URL, frameCount: Int) -> URL {
    var components = URLComponents(
      url: repository.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "title", value: title(for: report)),
      URLQueryItem(name: "body", value: body(for: report, frameCount: frameCount)),
    ]
    // URLComponents leaves `+` alone, and GitHub reads a bare `+` in a query
    // as a space, which would eat every "+ offset" in the trace.
    components.percentEncodedQuery = components.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    return components.url!
  }
}
