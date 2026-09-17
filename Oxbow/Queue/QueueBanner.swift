import SwiftUI

/// Show the error above the queue, preserving its toolbar and disabled Add control.
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
          // Wrap messages so suggested commands remain complete.
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
