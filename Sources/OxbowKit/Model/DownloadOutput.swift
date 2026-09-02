import Foundation

/// What the user gets. Deliberately two choices rather than three independent
/// toggles: a chat render in isolation has little use, and the composite is
/// what makes it worth producing at all. See docs/design/compositing.md §3.
///
/// Here rather than nested in `IntakeModel` because it is now a stored
/// preference, and because the Settings window renders the same value — one
/// type is what stops the two views inventing two vocabularies for it
/// (docs/design/settings.md §5).
public enum DownloadOutput: String, Codable, CaseIterable, Sendable {
  /// Listed first, and the factory value: a user who wanted only the video
  /// loses nothing but one click.
  case videoWithChat
  case video

  public static let `default`: DownloadOutput = .videoWithChat
}
