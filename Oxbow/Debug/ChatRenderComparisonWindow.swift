#if DEBUG
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import OxbowKit

/// The CLI's chat render beside the native renderer's, one scrubber driving both.
/// docs/design/native-chat-render.md §6, Phase 1 slice 1: the comparison tool of §8, inside the
/// app. DEBUG builds only.
struct ChatRenderComparisonWindow: View {
  @State private var model = ChatRenderComparison()
  @State private var isImportingChat = false
  @State private var isImportingReference = false

  var body: some View {
    VStack(spacing: 12) {
      toolbar
      if let error = model.error {
        Text(error)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }
      HStack(alignment: .top, spacing: 16) {
        pane("CLI", image: model.referenceFrame, placeholder: "Open the CLI's render of this chat")
        pane("Native", image: model.nativeFrame, placeholder: "Open a chat JSON")
      }
      .frame(maxHeight: .infinity)
      scrubber
    }
    .padding()
    .frame(minWidth: 980, minHeight: 640)
    .fileImporter(isPresented: $isImportingChat, allowedContentTypes: [.json]) { result in
      if case .success(let url) = result { model.openChat(url) }
    }
    .fileImporter(isPresented: $isImportingReference, allowedContentTypes: [.movie]) { result in
      if case .success(let url) = result { Task { await model.openReference(url) } }
    }
  }

  private var toolbar: some View {
    HStack {
      Button("Open Chat…") { isImportingChat = true }
      Button("Open CLI Render…") { isImportingReference = true }
      Spacer()
      // Match these to the flags the CLI render was made with, or the panes will differ.
      Toggle("Timestamps", isOn: $model.hasTimestamps)
      Toggle("Outline", isOn: $model.hasOutline)
      Toggle("Alternate backgrounds", isOn: $model.hasAlternateBackgrounds)
      Stepper(value: $model.fontSize, in: 6...48, step: 1) {
        Text("Font size \(model.fontSize, format: .number)")
      }
      .fixedSize()
    }
  }

  private func pane(_ title: String, image: CGImage?, placeholder: String) -> some View {
    VStack(spacing: 6) {
      Text(title).font(.headline)
      Group {
        if let image {
          Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.none)
            .aspectRatio(contentMode: .fit)
        } else {
          ContentUnavailableView(placeholder, systemImage: "text.bubble")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(.quaternary)
    }
  }

  private var scrubber: some View {
    HStack {
      Button("−1s") { model.step(seconds: -1) }
      Button("−1 frame") { model.step(frames: -1) }
      Slider(value: $model.seconds, in: 0...max(model.durationSeconds, 1))
        .disabled(model.durationSeconds == 0)
      Button("+1 frame") { model.step(frames: 1) }
      Button("+1s") { model.step(seconds: 1) }
      Text(model.timeLabel)
        .monospacedDigit()
        .frame(width: 150, alignment: .trailing)
    }
  }
}

/// Owns the loaded inputs and redraws both panes whenever the time or a setting moves.
@MainActor
@Observable
final class ChatRenderComparison {
  var seconds: Double = 0 { didSet { redraw() } }
  var fontSize: Double = 15 { didSet { rebuildRenderer() } }
  var hasTimestamps = false { didSet { rebuildRenderer() } }
  var hasOutline = false { didSet { rebuildRenderer() } }
  var hasAlternateBackgrounds = false { didSet { rebuildRenderer() } }

  private(set) var referenceFrame: CGImage?
  private(set) var nativeFrame: CGImage?
  private(set) var error: String?

  private var document: ChatDocument?
  private var renderer: NativeChatRenderer?
  private var reference: AVURLAsset?
  private var referenceDuration: Double = 0
  /// Taken from the CLI's render when one is open, so both panes are the same geometry.
  private var size = CGSize(width: 342, height: 1026)
  private var framerate = 30
  private var referenceTask: Task<Void, Never>?

  var durationSeconds: Double {
    max(referenceDuration, renderer.map { Double($0.duration.components.seconds) } ?? 0)
  }

  var timeLabel: String {
    let frame = Int((seconds * Double(framerate)).rounded())
    return String(format: "%.3fs · frame %d", seconds, frame)
  }

  func openChat(_ url: URL) {
    do {
      let accessing = url.startAccessingSecurityScopedResource()
      defer { if accessing { url.stopAccessingSecurityScopedResource() } }
      document = try ChatDocument.decode(from: Data(contentsOf: url))
      error = nil
      rebuildRenderer()
    } catch {
      self.error = "Could not read \(url.lastPathComponent): \(error)"
    }
  }

  func openReference(_ url: URL) async {
    let asset = AVURLAsset(url: url)
    do {
      guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        error = "\(url.lastPathComponent) has no video track"
        return
      }
      let (naturalSize, rate) = try await track.load(.naturalSize, .nominalFrameRate)
      referenceDuration = try await asset.load(.duration).seconds
      size = naturalSize
      framerate = max(Int(rate.rounded()), 1)

      reference = asset
      error = nil
      rebuildRenderer()
    } catch {
      self.error = "Could not open \(url.lastPathComponent): \(error)"
    }
  }

  func step(frames: Int) {
    seconds = min(max(seconds + Double(frames) / Double(framerate), 0), durationSeconds)
  }

  func step(seconds delta: Double) {
    seconds = min(max(seconds + delta, 0), durationSeconds)
  }

  private func rebuildRenderer() {
    guard let document else { return }
    renderer = NativeChatRenderer(
      document: document,
      request: RenderRequest(
        width: Int(size.width), height: Int(size.height), framerate: framerate, fontSize: fontSize,
        hasAlternateBackgrounds: hasAlternateBackgrounds, hasTimestamps: hasTimestamps,
        hasOutline: hasOutline))
    redraw()
  }

  private func redraw() {
    // Snap to a frame boundary so both panes show the same frame, not the same instant.
    let frame = Int((seconds * Double(framerate)).rounded())
    let time = Duration.seconds(Double(frame) / Double(framerate))
    nativeFrame = renderer?.frame(at: time)

    guard let reference else { return }
    referenceTask?.cancel()
    let at = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(framerate))
    referenceTask = Task {
      guard let image = await Self.frame(of: reference, at: at), !Task.isCancelled else { return }
      referenceFrame = image
    }
  }

  /// A generator per request, made and used off the main actor: the generator is not Sendable,
  /// and scrubbing never needs two at once.
  nonisolated private static func frame(of asset: AVURLAsset, at time: CMTime) async -> CGImage? {
    let generator = AVAssetImageGenerator(asset: asset)
    // Exact frames: a tolerance would compare the native frame against a neighbour.
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    return try? await generator.image(at: time).image
  }
}

#Preview("Empty") {
  ChatRenderComparisonWindow()
    .frame(width: 800, height: 700)
}
#endif
