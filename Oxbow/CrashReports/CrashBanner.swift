import SwiftUI
import OxbowKit

/// Offers to report the previous launch's crash as a GitHub issue. Nothing
/// leaves the Mac unless the user submits the form GitHub opens.
struct CrashBanner: View {
  let report: CrashReport
  let onReport: (URL) -> Void
  let onDismiss: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Spacer(minLength: 0)
      Label("Oxbow quit unexpectedly last time.", systemImage: "exclamationmark.triangle")
      Button("Report on GitHub…") {
        onReport(CrashIssue.url(for: report))
      }
      .help("Opens a new GitHub issue with the crash details filled in. Nothing is sent until you submit it.")
      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .bold))
      }
      .buttonStyle(.plain)
      .pointerStyle(.link)
      .accessibilityLabel("Dismiss")
      .help("Dismiss")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity)
    .background(.quaternary)
  }
}

#Preview {
  let json = """
    {"callStackTree": {"callStacks": []},
     "diagnosticMetaData": {"appVersion": "0.5.0", "exceptionType": 1, "signal": 11}}
    """
  CrashBanner(
    report: CrashReport(json: Data(json.utf8))!,
    onReport: { _ in },
    onDismiss: {})
  .frame(width: 720)
}
