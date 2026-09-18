import AppKit
import OxbowKit
import SwiftUI

/// Reserve a width-relative 16:9 slot to prevent row movement when images load.
struct ArchiveThumbnail: View {
  let url: URL?
  let store: ImageStore?
  var width: CGFloat = 48

  /// Optional subject label for meaningful category art; unlabelled frames are decorative.
  var label: String?

  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
      } else {
        Rectangle().fill(.quaternary)
          .overlay {
            Image(systemName: "gamecontroller")
              .font(.system(size: width * 0.3))
              .foregroundStyle(.tertiary)
          }
      }
    }
    .frame(width: width, height: width * 4 / 3)
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityLabel(label ?? "")
    .accessibilityHidden(label == nil)
    .task(id: url) {
      // Clear the previous archive image before fetching its replacement.
      image = nil
      guard let url, let store else { return }
      guard let data = await store.data(for: url) else { return }
      // Reject cancelled results: ImageStore does not check cancellation, so a recycled row may
      // receive a stale fetch after clearing its image.
      guard !Task.isCancelled else { return }
      image = NSImage(data: data)
    }
  }
}

#Preview("No image") {
  ArchiveThumbnail(url: nil, store: nil).padding()
}
