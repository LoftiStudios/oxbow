/// What the window has to show: a working queue, or the reason there is not
/// one.
///
/// One value rather than the pair of optionals this replaced. The pair could
/// express a state that cannot occur — a controller *and* a reason — and,
/// worse, it let the two real states be handled in two different places: the
/// branch inside `QueueView` was written for a combination its caller never
/// produced, so the explanation that actually shipped came from a duplicate
/// elsewhere with none of the surrounding chrome. Making the states
/// mutually exclusive by construction is what keeps that from recurring.
enum QueueContent {
  case ready(QueueController)
  /// A payload is missing (`AppComposition.helperMissing`) or the support
  /// directory could not be prepared. There is no engine, so there is no
  /// queue and nothing to add to it.
  case unavailable(String)
}
