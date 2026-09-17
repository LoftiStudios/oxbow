import SwiftUI
import OxbowKit

/// Update availability and manual-check results, separate from the queue's error banner.
struct UpdateBanner: View {
  let state: UpdateModel.State
  let onOpen: (URL) -> Void
  let onDismiss: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    switch state {
    case .idle:
      EmptyView()
    case .available(_, let url):
      strip {
        action(url)
      }
      .background(
        LinearGradient(
          colors: [palette.start, palette.end],
          startPoint: .leading,
          endPoint: .trailing))
      // Use the palette's tested foreground contrast rather than system primary text on a
      // custom gradient.
      .foregroundStyle(palette.foreground)
    case .upToDate:
      strip {
        Label("Oxbow is up to date.", systemImage: "checkmark.circle")
      }
      .background(.quaternary)
    case .failed(let reason):
      strip {
        Label("Could not check for updates. \(reason)", systemImage: "exclamationmark.triangle")
      }
      .background(.quaternary)
    }
  }

  private var palette: BannerPalette { Brand.updateBanner(for: colorScheme) }

  /// The shared shell: content pushed to the trailing edge, dismissal last.
  private func strip(@ViewBuilder content: () -> some View) -> some View {
    HStack(spacing: 12) {
      Spacer(minLength: 0)
      content()
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
  }

  /// Make the whole message the action target.
  private func action(_ url: URL) -> some View {
    Button {
      onOpen(url)
    } label: {
      Label("An update to Oxbow is available!", systemImage: "arrow.down.app")
        .font(.headline)
    }
    .buttonStyle(.plain)
    .pointerStyle(.link)
    .help("Opens the release page in your browser")
  }
}

#Preview("Update available (dark)") {
  UpdateBanner(
    state: .available(
      ReleaseVersion("0.3.0")!,
      URL(string: "https://github.com/LoftiStudios/oxbow/releases/tag/v0.3.0")!),
    onOpen: { _ in },
    onDismiss: {})
  .frame(width: 720)
  .preferredColorScheme(.dark)
}

#Preview("Update available (light)") {
  UpdateBanner(
    state: .available(
      ReleaseVersion("0.3.0")!,
      URL(string: "https://github.com/LoftiStudios/oxbow/releases/tag/v0.3.0")!),
    onOpen: { _ in },
    onDismiss: {})
  .frame(width: 720)
  .preferredColorScheme(.light)
}

#Preview("Up to date") {
  UpdateBanner(state: .upToDate, onOpen: { _ in }, onDismiss: {})
    .frame(width: 720)
}

#Preview("Check failed") {
  UpdateBanner(
    state: .failed("GitHub's rate limit was reached. Try again in an hour."),
    onOpen: { _ in },
    onDismiss: {})
  .frame(width: 720)
}
