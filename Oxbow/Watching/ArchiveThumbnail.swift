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
      // The fetch this resumes from may be for the archive this row used to
      // show: `.task(id:)` cancels the old one, but cancellation is
      // cooperative and `ImageStore.data(for:)` does not check it either, so
      // without this the stale fetch lands *after* the new task has cleared
      // `image` and puts another video's picture on this one. A row in a
      // scrolling list is recycled often enough for that to be ordinary, and
      // a wrong thumbnail is a wrong claim about what a video is.
      guard !Task.isCancelled else { return }
      image = NSImage(data: data)
    }
  }
}

#Preview("No image") {
  ArchiveThumbnail(url: nil, store: nil).padding()
}
