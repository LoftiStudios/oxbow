/// Shared sidebar destinations. Keep consumer switches exhaustive so new destinations cannot
/// silently resolve to Queue.
enum SidebarItem: Hashable {
  case queue
  case watching
  /// Use the persisted login key, not the independently chosen display name.
  case channel(String)
}
