import SwiftUI
import OxbowKit

/// The chat-render form, shown when the intake sheet's Render toggle is on.
///
/// Grouped exactly as the design doc's §7 table: Size, Colour, Elements,
/// Emotes, Encoding. Every control binds straight into `RenderOptions`, and
/// `IntakeModel.composedTemplate()` is what attaches a destination — this
/// view never sees or needs one.
struct RenderOptionsView: View {
  @Binding var options: RenderOptions

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      size
      colour
      elements
      emotes
      encoding
    }
  }

  // MARK: - Size

  private var size: some View {
    group("Size") {
      HStack(spacing: 8) {
        labeledNumber("Width", value: $options.width, width: 60)
        labeledNumber("Height", value: $options.height, width: 60)
        labeledNumber("FPS", value: $options.framerate, width: 50)
        labeledNumber("Font size", value: $options.fontSize, width: 50)
      }
      TextField("Font", text: $options.font)
        .textFieldStyle(.roundedBorder)
    }
  }

  // MARK: - Colour

  private var colour: some View {
    group("Colour") {
      ColorPicker("Background", selection: colorBinding($options.backgroundColor))
      ColorPicker("Message", selection: colorBinding($options.messageColor))
      Toggle("Alternate backgrounds", isOn: $options.hasAlternateBackgrounds)
      // Shown only while it does something — the CLI documents
      // `--alt-background-color` as inert without `--alternate-backgrounds`,
      // so a colour well the toggle has not enabled would just be a control
      // that silently does nothing.
      if options.hasAlternateBackgrounds {
        ColorPicker(
          "Alternate background", selection: colorBinding($options.alternateBackgroundColor))
      }
    }
  }

  // MARK: - Elements

  private var elements: some View {
    group("Elements") {
      Toggle("Badges", isOn: $options.hasBadges)
      Toggle("Timestamps", isOn: $options.hasTimestamps)
      Toggle("Sub / gift messages", isOn: $options.hasSubMessages)
      Toggle("Outline", isOn: $options.hasOutline)
      // Same reasoning as the alternate-background colour above: an outline
      // size means nothing while there is no outline to size.
      if options.hasOutline {
        labeledNumber("Outline size", value: $options.outlineSize, width: 50)
      }
    }
  }

  // MARK: - Emotes

  private var emotes: some View {
    group("Emotes") {
      // Surfaced deliberately rather than left as invisible defaults: 7TV
      // resolution is why the vendored CLI is pinned past 1.56.5
      // (CLAUDE.md), so the switch that controls it has to be visible.
      Toggle("BTTV", isOn: $options.isBTTVEnabled)
      Toggle("FFZ", isOn: $options.isFFZEnabled)
      Toggle("7TV", isOn: $options.isSTVEnabled)
      Toggle("Allow unlisted emotes", isOn: $options.allowsUnlistedEmotes)
    }
  }

  // MARK: - Encoding

  private var encoding: some View {
    group("Encoding") {
      labeledNumber("Bitrate (Mbps)", value: $options.bitrateMbps, width: 50)
      Toggle("Sharpen", isOn: $options.isSharpened)
    }
  }

  // MARK: - Building blocks

  private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      content()
    }
  }

  private func labeledNumber(_ label: String, value: Binding<Int>, width: CGFloat) -> some View {
    HStack(spacing: 4) {
      Text(label).font(.caption)
      TextField(label, value: value, format: .number)
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .frame(width: width)
    }
  }

  private func labeledNumber(_ label: String, value: Binding<Double>, width: CGFloat)
    -> some View
  {
    HStack(spacing: 4) {
      Text(label).font(.caption)
      TextField(label, value: value, format: .number)
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .frame(width: width)
    }
  }

  /// A `Color` binding over one of `RenderOptions`'s hex-string fields.
  ///
  /// `HexColor.color(fromHex:)` only fails on a string that never came from
  /// this app — the field always holds something `HexColor` itself wrote —
  /// so the `.black` fallback is unreachable in practice, not a real choice
  /// of default colour.
  private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
    Binding<Color>(
      get: { HexColor.color(fromHex: hex.wrappedValue) ?? .black },
      set: { hex.wrappedValue = HexColor.hex(from: $0) })
  }
}
