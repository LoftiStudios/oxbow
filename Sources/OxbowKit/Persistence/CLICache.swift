import Foundation

/// Emote, badge and emoji images shared across jobs, so a channel's emotes download once rather
/// than once per job.
///
/// The CLI keeps its cache in `<temp-path>/TwitchDownloader/<kind>/`, and each step gets its own
/// temp path. Rather than share the temp path, each step's `<kind>` folders are symlinks into
/// this cache for an allowlist of kinds; anything else the CLI writes, including kinds it adds
/// later, stays per step. Every kind shared here is keyed by a provider-assigned id, so two
/// channels cannot collide. docs/design/native-chat-render.md §3.2.
///
/// `Workspace` unlinks symlinks as leaves, so removing a job never reaches into the cache.
public struct CLICache: Sendable {
  public let root: URL

  /// Deliberately excludes `bits`: cheermotes key on a node id not proven unique across
  /// channels, and are too small to be worth the risk.
  static let sharedKinds = ["bttv", "ffz", "stv", "emotes", "badges", "emojis"]

  public init(root: URL) {
    self.root = root
  }

  /// Best-effort: a cache is an optimisation, so nothing here can fail a step. A folder that
  /// cannot be linked — a real one left by an earlier attempt, or a link that fails — is left
  /// for the CLI to use per step, as it always did.
  func link(into stepDirectory: URL) {
    let fileManager = FileManager.default
    let cliCache = stepDirectory.appending(path: "TwitchDownloader")
    guard (try? fileManager.createDirectory(at: cliCache, withIntermediateDirectories: true)) != nil
    else { return }

    for kind in Self.sharedKinds {
      let shared = root.appending(path: kind)
      let link = cliCache.appending(path: kind)
      // Check for a link before `fileExists`, which follows it.
      let isLinked = (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil
      guard !isLinked, !fileManager.fileExists(atPath: link.path) else { continue }
      guard (try? fileManager.createDirectory(at: shared, withIntermediateDirectories: true)) != nil
      else { continue }
      try? fileManager.createSymbolicLink(at: link, withDestinationURL: shared)
    }
  }

  /// Empties the cache if it has grown past `limit` bytes. All or nothing rather than
  /// least-recently-used: everything in it can be fetched again, and one rule is easier to
  /// trust than an eviction policy. Only safe while no step is running.
  public func trim(toAtMost limit: Int64) {
    let fileManager = FileManager.default
    guard let files = fileManager.enumerator(
      at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
    else { return }

    var total: Int64 = 0
    for case let file as URL in files {
      let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
      guard values?.isRegularFile == true else { continue }
      total += Int64(values?.totalFileAllocatedSize ?? 0)
      if total > limit {
        try? fileManager.removeItem(at: root)
        return
      }
    }
  }
}
