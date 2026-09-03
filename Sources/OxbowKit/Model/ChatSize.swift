import Foundation

/// The one control the deleted render-options form left behind (see
/// `docs/design/compositing.md` §4, §8).
///
/// A preset, not the numeric point size the old form exposed: the chat
/// column's width scales with the chosen quality, so a fixed number would
/// look right at one resolution and wrong at every other. `CompositeGeometry`
/// turns this into an actual size in proportion to the column it will sit in.
///
/// `Preferences` persists this enum's raw values in `UserDefaults`. Renaming
/// a case is therefore a storage-format change, not a refactor — it silently
/// orphans every saved preference, which falls back to the factory value with
/// no error anywhere. `ChatSizeTests.rawValuesArePersistedAndPinned` pins the
/// exact strings on purpose; if it fails after a rename, fix the case name,
/// not the test.
public enum ChatSize: String, Codable, CaseIterable, Sendable {
  case small
  case medium
  case large

  /// What a freshly opened intake window starts on, and what every other
  /// call site reaches for before the user has chosen — one constant so
  /// "medium" cannot drift between them.
  public static let `default`: ChatSize = .medium
}
