import SwiftUI

/// What the menu bar can do to the Watching pane, published by `QueueView`
/// through `focusedSceneValue`.
///
/// The same shape `QueueActions` uses, and for the same reason its own doc
/// comment gives: a menu item has no idea which scene it means, and a focused
/// value answers that for free. One action rather than a set, because there is
/// exactly one — Edit and Stop Watching act on a section a menu cannot know is
/// selected, so they stay on the section itself.
struct WatchingActions {
  var canRefresh: Bool
  var refresh: () async -> Void

  /// Stand-in for "the queue window is not frontmost, or its Watching pane is
  /// not showing" — the item disables itself without needing to know which.
  static let unavailable = WatchingActions(canRefresh: false, refresh: {})
}

struct WatchingActionsKey: FocusedValueKey {
  typealias Value = WatchingActions
}

extension FocusedValues {
  var watchingActions: WatchingActions? {
    get { self[WatchingActionsKey.self] }
    set { self[WatchingActionsKey.self] = newValue }
  }
}

/// Refresh, in the View menu beside the sidebar commands.
///
/// **In View rather than the Downloads menu.** Downloads acts on the selected
/// rows of the queue; this acts on the pane you are looking at, which is where
/// a Mac puts a refresh. It is also the only place ⌘R can live discoverably —
/// a key equivalent with no menu item behind it is a feature nobody finds.
struct WatchingCommands: Commands {
  @FocusedValue(\.watchingActions) private var actions

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      let actions = actions ?? .unavailable
      Button("Refresh Watched Channels") {
        Task { await actions.refresh() }
      }
      .keyboardShortcut("r")
      // False while a sweep is already running, matching the toolbar button —
      // see its own comment for why `refreshNow()` during a sweep would
      // silently do nothing.
      .disabled(!actions.canRefresh)
    }
  }
}
