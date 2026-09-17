import AppIntents

/// Shortcut phrases also surface the intent in Spotlight. Every phrase must include
/// applicationName.
struct OxbowShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: DownloadTwitchVideoIntent(),
      phrases: [
        "Download a Twitch video with \(.applicationName)",
        "Download a VOD with \(.applicationName)",
        "Add a download to \(.applicationName)",
      ],
      shortTitle: "Download Twitch Video",
      systemImageName: "arrow.down.circle")
  }
}
