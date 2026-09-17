import AppIntents
import Foundation
import OxbowKit

/// Testable intent submission sequence, separate from QueueHost and AppIntents result types.
enum IntentSubmission {

  /// Duplicates succeed so they do not abort Shortcuts Repeat with Each workflows.
  enum Outcome: Equatable {
    case queued(String)
    case alreadyQueued(String)

    /// Return the output base name for both new and existing jobs.
    var value: String {
      switch self {
      case .queued(let name), .alreadyQueued(let name): name
      }
    }

    var dialog: String {
      switch self {
      case .queued(let name): "Queued \(name)"
      case .alreadyQueued(let name): "Already queued \(name)"
      }
    }

    var notificationTitle: String {
      switch self {
      case .queued: "Added to Oxbow"
      case .alreadyQueued: "Already in the queue"
      }
    }

    var notificationBody: String { value }
  }

  /// Single-line refusals for Spotlight, naming intent parameters rather than intake controls.
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

  /// Apply overrides before load(), which resolves quality using output and qualityCap.
  /// Overrides affect only this run. IntakeAdd records after successful enqueue; nil recording
  /// disables writes for tests. A nil helperVersion records facts without an unstamped raw
  /// payload.
  @discardableResult
  static func submit(
    link: String,
    quality: QualityCap?,
    output: DownloadOutput?,
    chatSize: ChatSize?,
    destination: URL?,
    existingJobs: [Job] = [],
    into model: IntakeModel,
    recording: VideoRecording? = nil,
    helperVersion: String? = AboutInfo.main.helperVersion) async throws -> Outcome
  {
    model.linkText = link
    guard !model.isLinkUnrecognized, let target = model.target else {
      throw Failure.unrecognizedLink
    }

    // Check normalized identifiers before fetching. Only unfinished jobs block duplicates;
    // failed or cancelled jobs must remain retryable from the intent.
    if let existing = existingJobs.first(where: {
      $0.status.isUnfinished && $0.mediaIdentifier == target.identifier
    }) {
      return .alreadyQueued(existing.title)
    }

    if let quality { model.qualityCap = quality }
    if let output { model.output = output }
    if let chatSize { model.chatSize = chatSize }
    if let destination { model.folder = destination }

    await model.load()

    // Report specific validation errors before add(), using the corresponding intent parameter
    // names.
    if let problem = model.chatProblem {
      throw Failure.refused(rewordForIntent(problem))
    }
    if let problem = model.compositeProblem {
      throw Failure.refused(rewordForIntent(problem))
    }

    // Keep disk space advisory, matching the window. Use IntakeAdd so both entry points record
    // only after enqueue succeeds.
    guard await IntakeAdd.perform(
      model, recording: recording, helperVersion: helperVersion)
    else {
      throw Failure.refused(model.addFailure ?? "Oxbow could not build that download.")
    }

    return .queued(model.outputBaseName)
  }

  private static func rewordForIntent(_ message: String) -> String {
    message
      .replacingOccurrences(of: "Choose \"Video\"", with: "Set Output to \"Video only\"")
      .replacingOccurrences(of: "Pick another quality", with: "Set a different Quality")
  }
}

/// Queue a VOD or clip in the background; keep the app running to process its queue.
struct DownloadTwitchVideoIntent: AppIntent {
  static let title: LocalizedStringResource = "Download Twitch Video"
  static let description = IntentDescription(
    """
    Adds a Twitch VOD or clip to Oxbow's queue. Anything you leave blank uses \
    your saved Oxbow settings.
    """,
    categoryName: "Downloads")

  static let openAppWhenRun = false

  /// Accept String so bare ids, clip slugs, and scheme-less links reach TwitchLink.parse.
  @Parameter(title: "Link")
  var link: String

  @Parameter(title: "Quality")
  var quality: QualityCap?

  @Parameter(title: "Output")
  var output: DownloadOutput?

  @Parameter(title: "Chat Text Size")
  var chatSize: ChatSize?

  /// Use URL for a directory reference; IntentFile represents eagerly loaded file content.
  /// Unverified: whether Shortcuts presents a folder picker for this parameter
  /// (docs/design/automation.md §3.1).
  @Parameter(title: "Destination")
  var destination: URL?

  /// Keep only link in the summary; overrides appear under Show More.
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
    let content = await QueueHost.shared.ready()
    switch content {
    case .unavailable(let message):
      throw IntentSubmission.Failure.unavailable(message)

    case .ready(let controller):
      // Create a fresh model seeded from saved preferences for each run.
      let outcome = try await IntentSubmission.submit(
        link: link,
        quality: quality,
        output: output,
        chatSize: chatSize,
        destination: destination,
        existingJobs: controller.jobs,
        into: IntakeModel(controller: controller),
        recording: QueueHost.shared.videoRecording)

      // Keep notifications outside the testable submission function. Only the intent needs
      // them; the window shows the queue.
      QueueHost.shared.notifyIntentOutcome(outcome)

      return .result(value: outcome.value, dialog: "\(outcome.dialog)")
    }
  }
}
