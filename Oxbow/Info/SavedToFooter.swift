import AppKit
import SwiftUI
import OxbowKit

/// Shared destination footer for Get Info and the inspector. Reveal delivered files, falling
/// back to the destination folder when none are recorded.
struct SavedToFooter: View {
  let info: JobInfo

  var body: some View {
    // Drop the label when needed to leave space for the folder name in narrow inspectors.
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
      // Preserve the button label when the folder name truncates.
      .fixedSize()
    }
  }
}
