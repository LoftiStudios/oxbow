import Foundation
import OxbowKit

/// What a Get Info window is about.
///
/// **A video, not a download.** Get Info used to be keyed by `JobID`, which
/// meant it could only ever describe something the queue still held — so a
/// watched archive nobody had downloaded was not addressable at all, and a
/// finished download stopped being describable the moment its job was cleared
/// out. Keying on the video makes the job a *section* of the window rather
/// than the thing the window is about, which is what lets the queue and the
/// Watching pane open the same window for the same video
/// (`docs/design/video-record.md` §4.2).
///
/// **The job case is not a legacy path.** `JobInfo.sourceIdentifier` is nil
/// for a job carrying no video, clip or chat request with an id — a render-only
/// job reached through the library, say. Rather than make such a job
/// un-openable, it stays addressable by the only identity it has.
///
/// `Codable` and `Hashable` because `WindowGroup(id:for:)` requires both of
/// its value type; `JobID` already is, and a `String` needs no help.
enum InfoTarget: Codable, Hashable {
  case video(String)
  case job(JobID)
}
