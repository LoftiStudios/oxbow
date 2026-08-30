import SwiftUI

/// The measurements every queue row shares, in one place because the whole
/// point of them is that rows agree.
///
/// Rows in this list are not uniform — some have a disclosure control and some
/// do not, some carry a progress bar under the title and some carry a failure
/// message. Left to lay themselves out, each row put its status icon wherever
/// its own contents happened to start, so the icon column zigzagged and a
/// failure message sat further left than the title it belonged to. These
/// constants are what make a mixed list read as one list.
enum QueueMetrics {
  /// The disclosure column. Reserved on **every** row, occupied only by rows
  /// that have steps to disclose — that reservation is what keeps the status
  /// icons in a straight line.
  static let gutter: CGFloat = 14

  /// The status icon column.
  static let icon: CGFloat = 16

  static let iconSpacing: CGFloat = 6
  static let gutterSpacing: CGFloat = 4

  /// How far anything below a title has to indent to sit under that title
  /// rather than under its icon: progress bars, failure messages, the details
  /// disclosure, and nested step rows.
  static let contentIndent: CGFloat = icon + iconSpacing

  /// The height a row's first line occupies, so the gutter chevron and the
  /// status icon centre on the title rather than floating above it.
  static let titleLine: CGFloat = 18
}

/// What a status *means*, kept separate from the colour that says so.
///
/// `JobPresentation` is deliberately free of SwiftUI — it is a pure, testable
/// enum of derivations that `OxbowTests` calls synchronously — so it names the
/// tone and this file, in the view layer, decides what tone looks like.
extension JobPresentation.Tone {
  /// Takes the appearance rather than reading it, because the one tone that is
  /// ours rather than the system's has a value per appearance
  /// (`Brand.progressFill(for:)`). A dynamic `NSColor` would spare the three
  /// call sites this argument, but it resolves against `NSAppearance` instead
  /// of the SwiftUI environment — so a `#Preview` pinned to `.light`, or an
  /// `ImageRenderer` sheet drawing both appearances side by side, would show
  /// the icon in one appearance and the bar beneath it in the other.
  func color(for scheme: ColorScheme) -> Color {
    switch self {
    // Two greys, and which one says whether the step is still going to
    // happen — see `Tone`. Both are system semantic colours, so they follow
    // the appearance and the increased-contrast setting without a Brand
    // value of their own.
    case .neutral: Color(nsColor: .tertiaryLabelColor)
    case .pending: .secondary
    // Deliberately the progress fill itself, not a colour near it: the running
    // icon sits directly above the bar it describes, and two purples that are
    // almost the same read as a mistake where one reads as one thing.
    case .active: Brand.progressFill(for: scheme)
    case .success: .green
    case .error: .red
    }
  }
}
