import AppKit
import SwiftUI
import OxbowKit

/// Where a download landed, and the way to go look at it.
///
/// **Rendered by both `JobInfoWindow` and `InspectorPane`**, which is the
/// point: "where did that go" is the question asked most often about a
/// finished download, and the answer must not be phrased two ways. Lifted out
/// of the window when the inspector needed it, the same move
/// `ChannelActionsMenu` and `VideoInfoLoad` already make.
///
/// **Falls back to the folder when no file is recorded.** A job that never
/// delivered still has a destination worth opening, and `Show in Finder`
/// pointing at an empty folder is a better answer than a disabled button —
/// disabled only when there is neither.
struct SavedToFooter: View {
  let info: JobInfo

  var body: some View {
    // **Two arrangements, chosen by what fits.** The window has room for the
    // "Saved to" label; the inspector's 300pt column does not, and forcing it
    // there truncated the folder to "D…ds" — a name so abbreviated it stops
    // being one. `ViewThatFits` picks per surface and keeps picking correctly
    // when the inspector is dragged wider, which a fixed breakpoint would not.
    ViewThatFits(in: .horizontal) {
      row(showingLabel: true)
      row(showingLabel: false)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
  }

  private func row(showingLabel: Bool) -> some View {
    HStack(spacing: 8) {
      if showingLabel {
        Text("Saved to").foregroundStyle(.secondary)
      }
      if let folder = info.destinationFolder {
        Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path(percentEncoded: false)))
          .resizable()
          .frame(width: 16, height: 16)
        Text(folder.lastPathComponent)
          .lineLimit(1)
          .truncationMode(.middle)
          // The full path is always one hover away, whichever arrangement won.
          .help("Saved to \(folder.path(percentEncoded: false))")
      } else {
        Text("Unknown").foregroundStyle(.secondary)
      }

      Spacer(minLength: 8)

      Button("Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting(
          info.deliveredFiles.isEmpty
            ? [info.destinationFolder].compactMap { $0 }
            : info.deliveredFiles)
      }
      .disabled(info.destinationFolder == nil && info.deliveredFiles.isEmpty)
      // Never the thing that gives way: a control losing its own name is
      // worse than a shortened folder.
      .fixedSize()
    }
  }
}
