import Foundation

/// Shared delivered-output choice for intake, preferences, and Settings; see
/// docs/design/compositing.md §3.
public enum DownloadOutput: String, Codable, CaseIterable, Sendable {
  case videoWithChat
  case video

  public static let `default`: DownloadOutput = .videoWithChat
}
