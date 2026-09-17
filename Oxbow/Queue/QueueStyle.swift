import SwiftUI

/// Shared row columns and spacing keep mixed queue states aligned.
enum QueueMetrics {
  /// Reserve the disclosure column on every row.
  static let gutter: CGFloat = 14

  static let icon: CGFloat = 16

  static let iconSpacing: CGFloat = 6
  static let gutterSpacing: CGFloat = 4

  /// Indent progress, failures, and nested steps under the title rather than its icon.
  static let contentIndent: CGFloat = icon + iconSpacing

  /// Centre status and disclosure icons on the title line.
  static let titleLine: CGFloat = 18
}

/// Map view-independent status tones to SwiftUI colours.
extension JobPresentation.Tone {
  /// Use the SwiftUI colour scheme so pinned previews and rendered views match their progress
  /// bars; NSAppearance may differ.
  func color(for scheme: ColorScheme) -> Color {
    switch self {
    // Semantic greys follow appearance and increased contrast.
    case .neutral: Color(nsColor: .tertiaryLabelColor)
    case .pending: .secondary
    // Match the active icon to its progress bar's fill.
    case .active: Brand.progressFill(for: scheme)
    case .success: .green
    case .error: .red
    }
  }
}
