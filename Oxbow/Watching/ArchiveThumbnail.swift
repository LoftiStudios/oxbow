import AppKit
import OxbowKit
import SwiftUI

/// An archive's preview image, from the image store.
///
/// **16:9 by aspect ratio against a given width, never a fixed height.** The
/// same reasoning `VideoCard`'s own thumbnail keeps: reserving the shape
/// rather than the pixels means the row does not jump when the image lands,
/// and does not have to be re-tuned when the row's width changes.
struct ArchiveThumbnail: View {
  let url: URL?
  let store: ImageStore?
  var width: CGFloat = 64

  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
      } else {
        Rectangle().fill(.quaternary)
          .overlay {
            Image(systemName: "film")
              .font(.system(size: width * 0.3))
              .foregroundStyle(.tertiary)
          }
      }
    }
    .frame(width: width, height: width * 9 / 16)
    .clipShape(RoundedRectangle(cornerRadius: 4))
    .accessibilityHidden(true)
    .task(id: url) {
      // Cleared first, matching `ChannelAvatar`: `.task(id:)` re-runs when
      // the archive changes, and without this the previous row's frame
      // lingers over the new one until the new fetch lands.
      image = nil
      guard let url, let store else { return }
      guard let data = await store.data(for: url) else { return }
      image = NSImage(data: data)
    }
  }
}

#Preview("No image") {
  ArchiveThumbnail(url: nil, store: nil).padding()
}
