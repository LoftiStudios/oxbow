import SwiftUI
import OxbowKit

/// The chat-render form, shown when the intake sheet's Render toggle is on.
///
/// Grouped exactly as the design doc's §7 table: Size, Colour, Elements,
/// Emotes, Encoding. Every control binds straight into `RenderOptions`, and
/// `IntakeModel.composedTemplate()` is what attaches a destination — this
/// view never sees or needs one.
///
/// **Sections, not a stack.** This is placed directly inside `IntakeSheet`'s
/// `Form`, so its body is a `Group` of `Section`s that the form lays out
/// alongside its own — one label column and one set of row metrics down the
/// whole sheet. Its previous life as a `VStack` of hand-drawn caption headers
/// inside a fixed-height `ScrollView` is what made this part of the sheet feel
/// like a separate, denser app bolted into the middle of the first one.
struct RenderOptionsView: View {
  @Binding var options: RenderOptions

  var body: some View {
    Group {
      size
      colour
      elements
      emotes
      encoding
    }
  }

  // MARK: - Size

  private var size: some View {
    Section("Size") {
      LabeledContent("Dimensions") {
        HStack(spacing: 6) {
          number("Width", value: $options.width)
          Text("×").foregroundStyle(.secondary)
          number("Height", value: $options.height)
        }
      }
      LabeledContent("Frame rate") { number("Frame rate", value: $options.framerate) }
      TextField("Font", text: $options.font)
      LabeledContent("Font size") { number("Font size", value: $options.fontSize) }
      problems
    }
  }

  /// Why Add is disabled, spelled out.
  ///
  /// The alternative — clamping a typed value back into range as the user
  /// types — fights the text field: half of "1080" is "1", which would be
  /// silently rewritten to the minimum before the next keystroke arrived.
  /// Showing the rule and refusing Add matches how the trim fields already
  /// behave.
  @ViewBuilder
  private var problems: some View {
    let problems = options.validationProblems
    if !problems.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(problems, id: \.self) { problem in
          Label(problem, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Colour

  private var colour: some View {
    Section("Colour") {
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
    Section("Elements") {
      Toggle("Badges", isOn: $options.hasBadges)
      Toggle("Timestamps", isOn: $options.hasTimestamps)
      Toggle("Sub / gift messages", isOn: $options.hasSubMessages)
      Toggle("Outline", isOn: $options.hasOutline)
      // Same reasoning as the alternate-background colour above: an outline
      // size means nothing while there is no outline to size.
      if options.hasOutline {
        LabeledContent("Outline size") { number("Outline size", value: $options.outlineSize) }
      }
    }
  }

  // MARK: - Emotes

  private var emotes: some View {
    Section("Emotes") {
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
    Section("Encoding") {
      LabeledContent("Bitrate") {
        HStack(spacing: 6) {
          number("Bitrate", value: $options.bitrateMbps)
          Text("Mbps").foregroundStyle(.secondary)
        }
      }
      Toggle("Sharpen", isOn: $options.isSharpened)
    }
  }

  // MARK: - Building blocks

  /// A numeric field sized to its content rather than stretched across the
  /// form's whole value column — a four-digit pixel count in a 300pt field
  /// reads as a mistake.
  ///
  /// Two overloads rather than one over `Numeric`, because `.number` resolves
  /// to a different `FormatStyle` for each and cannot be named generically.
  private func number(_ label: String, value: Binding<Int>) -> some View {
    field(TextField(label, value: value, format: .number))
  }

  private func number(_ label: String, value: Binding<Double>) -> some View {
    field(TextField(label, value: value, format: .number))
  }

  private func field(_ textField: some View) -> some View {
    textField
      .labelsHidden()
      .frame(width: 72)
      .multilineTextAlignment(.trailing)
      .monospacedDigit()
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

#Preview("Defaults") {
  @Previewable @State var options = RenderOptions()
  Form {
    RenderOptionsView(options: $options)
  }
  .formStyle(.grouped)
  .frame(width: 520, height: 640)
}

#Preview("Every conditional row showing") {
  @Previewable @State var options: RenderOptions = {
    var options = RenderOptions()
    options.hasAlternateBackgrounds = true
    options.hasOutline = true
    // Out of range, so the validation row is on screen too.
    options.width = 1
    return options
  }()
  Form {
    RenderOptionsView(options: $options)
  }
  .formStyle(.grouped)
  .frame(width: 520, height: 640)
}
