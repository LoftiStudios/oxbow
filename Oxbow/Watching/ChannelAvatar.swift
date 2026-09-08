import AppKit
import OxbowKit
import SwiftUI

/// A channel's avatar, from the image store, with a placeholder in every case
/// it cannot show one.
///
/// **Not `AsyncImage`.** That fetches straight from the network with no
/// durable copy, which is the exact behaviour `ImageStore` exists to replace:
/// an expired archive's image has to survive its URL. `AsyncImage` would also
/// refetch on every scroll that recycled the view.
struct ChannelAvatar: View {
  let url: URL?
  let store: ImageStore?
  var size: CGFloat = 20

  @State private var image: NSImage?

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        // Holds its space from the first frame, so a header does not resize
        // when the image lands — and so a channel with no avatar looks
        // deliberate rather than broken.
        RoundedRectangle(cornerRadius: size / 5)
          .fill(.quaternary)
          .overlay {
            Image(systemName: "person.fill")
              .font(.system(size: size * 0.55))
              .foregroundStyle(.tertiary)
          }
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size / 5))
    .accessibilityHidden(true)
    .task(id: url) {
      // Cleared first: `.task(id:)` re-runs when the channel changes, and
      // without this the previous channel's face lingers over the new name
      // until the new fetch lands.
      image = nil
      guard let url, let store else { return }
      guard let data = await store.data(for: url) else { return }
      // The fetch this resumes from may belong to the channel this header
      // used to show. `.task(id:)` cancels the old one, but cancellation is
      // cooperative and `ImageStore.data(for:)` does not check it either, so
      // a stale fetch would land after the new task cleared `image` and put
      // the previous channel's face above this channel's name.
      guard !Task.isCancelled else { return }
      image = NSImage(data: data)
    }
  }
}

#Preview("No avatar available") {
  ChannelAvatar(url: nil, store: nil, size: 48).padding()
}

#Preview("Beside a channel name, at header size") {
  HStack(spacing: 6) {
    ChannelAvatar(url: nil, store: nil)
    Text("Hall_of_Tech")
  }
  .padding()
}
