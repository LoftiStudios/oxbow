/// Mutually exclusive ready and unavailable states for the queue window.
enum QueueContent {
  case ready(QueueController)
  /// A payload is missing (`AppComposition.helperMissing`) or the support
  /// directory could not be prepared. There is no engine, so there is no
  /// queue and nothing to add to it.
  case unavailable(String)
}
