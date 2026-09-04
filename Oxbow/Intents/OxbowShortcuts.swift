import AppIntents

/// The phrases that reach the action without opening Shortcuts.
///
/// macOS 26 surfaces third-party App Intents in Spotlight automatically, and
/// this is what names them there. It is the reason the intent was built: it
/// reaches everyone with ⌘Space, where Shortcuts reaches the few people who
/// open Shortcuts.
///
/// `.applicationName` is required in every phrase.
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
