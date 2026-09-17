import OxbowKit

/// Carry archive identity and frozen watch settings to intake, independent of current global
/// preferences.
struct PendingIntake: Equatable {
  /// A bare archive id is valid intake link text.
  var archiveID: String
  var settings: Watch.Settings
}
