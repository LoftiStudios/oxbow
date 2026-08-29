import SwiftUI
import OxbowKit

/// The strip that says a new version exists, and the two quieter strips the
/// Check for Updates… menu item can produce.
///
/// Deliberately not a variant of `QueueBanner`. That one exists to explain
/// that something is broken — orange triangle, two lines, no dismissal — and
/// bending it to also carry good news would have meant a severity flag whose
/// two branches shared no layout. Two small views beat one general one here.
///
/// This is the only place in the app that paints a brand colour rather than a
/// system one. It is the one moment that is Oxbow's rather than macOS's.
struct UpdateBanner: View {
  let state: UpdateModel.State
  let onOpen: (URL) -> Void
  let onDismiss: () -> Void

  /// The band inverts between appearances — a deep gradient carrying white
  /// in dark mode, a pale one carrying near-black in light mode. Reusing
  /// the dark band on a white window reads as something dropped on top of
  /// the app rather than part of it.
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
      // The palette's own foreground, not `.primary`: the band is a brand
      // colour rather than a system one, so the system's idea of primary text
      // is not guaranteed to be legible on it. `BrandTests` holds each
      // palette's foreground above WCAG AA against its own two ends.
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

  /// The message itself is the control, so the whole sentence is the target
  /// rather than a separate button repeating it.
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
      URL(string: "https://github.com/barclay/oxbow/releases/tag/v0.3.0")!),
    onOpen: { _ in },
    onDismiss: {})
  .frame(width: 720)
  .preferredColorScheme(.dark)
}

#Preview("Update available (light)") {
  UpdateBanner(
    state: .available(
      ReleaseVersion("0.3.0")!,
      URL(string: "https://github.com/barclay/oxbow/releases/tag/v0.3.0")!),
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
