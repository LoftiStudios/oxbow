import AppKit
import OxbowKit
import SwiftUI

/// Load durable cached avatars through ImageStore, with a placeholder on failure.
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
      // Clear the old avatar before loading a different channel.
      image = nil
      guard let url, let store else { return }
      guard let data = await store.data(for: url) else { return }
      // Reject cancelled results because ImageStore does not check cancellation itself.
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
