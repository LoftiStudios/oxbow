import SwiftUI

/// The window's explanation strip: something is wrong, and the queue stays on
/// screen anyway.
///
/// Deliberately not `ContentUnavailableView`, which replaces the content
/// rather than sitting above it. Design §6 asks for a banner *and* a disabled
/// `+`, so the toolbar and whatever the list would otherwise draw both have
/// to remain visible behind the explanation.
struct QueueBanner: View {
  let title: String
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        Text(message)
          .font(.callout)
          .foregroundStyle(.secondary)
          // The messages name a command to run, so they must wrap rather
          // than truncate — half a shell command helps nobody.
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary)
    .accessibilityElement(children: .combine)
  }
}
