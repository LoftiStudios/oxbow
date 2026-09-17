import Foundation
import OxbowKit

/// Get Info identity shared by queue and archive entries. Jobs without a video identifier, such
/// as render-only jobs, use their JobID instead.
enum InfoTarget: Codable, Hashable {
  case video(String)
  case job(JobID)
}
