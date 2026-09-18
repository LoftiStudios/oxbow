import SwiftUI

/// Publish Watching's Refresh action through the focused scene. Channel-specific actions remain
/// on the channel menus.
struct WatchingActions {
  var canRefresh: Bool
  var refresh: () async -> Void

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

/// Refresh belongs in View because it acts on the visible pane, not selected queue downloads.
struct WatchingCommands: Commands {
  @FocusedValue(\.watchingActions) private var actions

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      let actions = actions ?? .unavailable
      Button("Refresh Watched Channels") {
        Task { await actions.refresh() }
      }
      .keyboardShortcut("r")
      .disabled(!actions.canRefresh)
    }
  }
}
