/// Which destination the main window's sidebar is showing.
///
/// **Lifted out of `QueueView` so it can be named from outside a view.**
/// `InspectorSubject.resolve` switches on it (`docs/design/inspector.md` §3.3)
/// and is a pure function precisely so it can be exercised without building
/// anything — which a `private` nested enum makes impossible.
///
/// **Never carries a default case at its consumers.** Both switches that read
/// it are written out in full: a catch-all is what would silently land a new
/// destination on the queue, and letting the compiler find every site is the
/// whole technique (`watching-navigation.md` §4.3).
enum SidebarItem: Hashable {
  case queue
  case watching
  /// One watched channel, by login.
  ///
  /// **Login, not display name.** `docs/design/video-record.md` §3.4: a
  /// display name can be Japanese while the login is ASCII, and neither
  /// derives from the other. The login is what `watches.json` is keyed on
  /// and what every lookup here has to use.
  case channel(String)
}
