public enum SpawnError: Error, Equatable {
  case pipeFailed(Int32)
  case spawnFailed(code: Int32, message: String)
}
