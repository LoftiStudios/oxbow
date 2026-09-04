import AppIntents
import Foundation
import OxbowKit

/// Everything the intent does to a model, with no `QueueHost` and no
/// `AppIntents` result types in the way.
///
/// Split out so the sequencing below is testable. `perform()` cannot be: it
/// reaches `QueueHost.shared`, which is the app's real engine.
enum IntentSubmission {

  /// A refusal, in one sentence, because Spotlight shows one line.
  ///
  /// `IntakeModel`'s own refusals were written for a form with room under it,
  /// and two of them end by naming a control this action does not have —
  /// "Choose \"Video\"" and "Pick another quality". Those become the
  /// parameter names.
  enum Failure: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case unrecognizedLink
    case unavailable(String)
    case refused(String)

    var localizedStringResource: LocalizedStringResource {
      switch self {
      case .unrecognizedLink:
        "That is not a Twitch video or clip address."
      case .unavailable(let message):
        "\(message)"
      case .refused(let message):
        "\(message)"
      }
    }
  }

  /// Applies the overrides, fetches, composes and enqueues. Returns the base
  /// name the job's files will share.
  ///
  /// **The overrides go on before `load()`, and that ordering is load-bearing.**
  /// `load()` reads `output` to decide whether resolution must skip a
  /// rendition a composite cannot use (`settings.md` §3.4), and reads
  /// `qualityCap` to pick the rendition at all. Applied afterwards, the
  /// quality resolves against the wrong policy and `quality` ends up naming a
  /// rendition nobody asked for.
  ///
  /// **Nothing here saves a preference.** `saveDefaultsIfRequested()` is
  /// driven by the intake's checkbox, which this never sets. An override is a
  /// decision about one run.
  @discardableResult
  static func submit(
    link: String,
    quality: QualityCap?,
    output: DownloadOutput?,
    chatSize: ChatSize?,
    destination: URL?,
    into model: IntakeModel) async throws -> String
  {
    model.linkText = link
    guard !model.isLinkUnrecognized, model.target != nil else {
      throw Failure.unrecognizedLink
    }

    if let quality { model.qualityCap = quality }
    if let output { model.output = output }
    if let chatSize { model.chatSize = chatSize }
    if let destination { model.folder = destination }

    await model.load()

    // Checked before `add()` so the reason is the specific one rather than
    // `addFailure`'s generic "could not build that download". Both of these
    // end in an instruction naming an intake control; reworded for the
    // parameter that stands in for it here.
    if let problem = model.chatProblem {
      throw Failure.refused(rewordForIntent(problem))
    }
    if let problem = model.compositeProblem {
      throw Failure.refused(rewordForIntent(problem))
    }

    // The disk-space warning is deliberately *not* consulted. In the window
    // it is a warning with a remedy and Add stays enabled; refusing here a
    // job the window would have allowed makes the two disagree, which is
    // worse than a job that runs out of room in the way the window already
    // permits (docs/design/automation.md §7).
    guard await model.add() else {
      throw Failure.refused(model.addFailure ?? "Oxbow could not build that download.")
    }
    return model.outputBaseName
  }

  private static func rewordForIntent(_ message: String) -> String {
    message
      .replacingOccurrences(of: "Choose \"Video\"", with: "Set Output to \"Video only\"")
      .replacingOccurrences(of: "Pick another quality", with: "Set a different Quality")
  }
}

/// Queue a Twitch VOD or clip without opening Oxbow.
///
/// `openAppWhenRun = false`: the system launches the app in the background to
/// run this, and no window comes up. Oxbow stays running afterwards because
/// it has a queue to work — which is what the Dock badge and the completion
/// notification from 0.4.0 are for.
struct DownloadTwitchVideoIntent: AppIntent {
  static let title: LocalizedStringResource = "Download Twitch Video"
  static let description = IntentDescription(
    """
    Adds a Twitch VOD or clip to Oxbow's queue. Anything you leave blank uses \
    your saved Oxbow settings.
    """,
    categoryName: "Downloads")

  /// No window. See the type's own comment.
  static let openAppWhenRun = false

  /// `String`, not `URL`: `TwitchLink.parse` accepts a bare VOD id, a bare
  /// clip slug and a scheme-less host, and a `URL` parameter would reject the
  /// first two before Oxbow ever saw them.
  @Parameter(title: "Link")
  var link: String

  @Parameter(title: "Quality")
  var quality: QualityCap?

  @Parameter(title: "Output")
  var output: DownloadOutput?

  @Parameter(title: "Chat Text Size")
  var chatSize: ChatSize?

  /// **`URL?`, not `IntentFile?` with `supportedContentTypes: [.folder]`.**
  /// The brief called for `IntentFile`, but `IntentFile.data` (in the real
  /// AppIntents.framework, checked directly against the macOS 26 SDK's
  /// `.swiftinterface`) is a non-optional, eagerly-loaded `Data` — the type
  /// represents file *content*, not a directory reference, and nothing about
  /// it promises a folder round-trips to a usable URL for an app that isn't
  /// sandboxed. `supportedContentTypes:` itself is only exposed on the
  /// `IntentFile`-typed `@Parameter` overload. `URL` is a first-class,
  /// natively-supported intent parameter type (`Foundation.URL:
  /// AppIntents._IntentValue` in the same interface) with no content-type
  /// machinery to fight, and Shortcuts already renders a folder picker for a
  /// plain `URL` parameter. This is simpler than the brief's form, not a
  /// workaround for one.
  @Parameter(title: "Destination")
  var destination: URL?

  /// Only `link` in the summary line, so Spotlight shows one field rather
  /// than five. The four overrides collapse into "Show More".
  static var parameterSummary: some ParameterSummary {
    Summary("Download \(\.$link)") {
      \.$quality
      \.$output
      \.$chatSize
      \.$destination
    }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    // Bound once, deliberately, rather than switched on twice: `ready()`
    // resolves the engine exactly once and caches the result, so a second
    // call was never wrong — only harder to read, since it looks like two
    // independent resolutions might disagree. Binding once removes the doubt.
    let content = await QueueHost.shared.ready()
    switch content {
    case .unavailable(let message):
      throw IntentSubmission.Failure.unavailable(message)

    case .ready(let controller):
      // A fresh model per run, seeded from `Preferences` by this initializer.
      // On a machine nobody has configured, that is best available, with
      // chat, into ~/Downloads — the right answer, arranged by needing no
      // code.
      let name = try await IntentSubmission.submit(
        link: link,
        quality: quality,
        output: output,
        chatSize: chatSize,
        destination: destination,
        into: IntakeModel(controller: controller))

      return .result(value: name, dialog: "Queued \(name)")
    }
  }
}
