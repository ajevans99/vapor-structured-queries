/// Errors produced by the VaporStructuredQueries runtime.
public enum DatabaseRuntimeError: Error, Equatable, Sendable {
  /// No default database has been configured.
  case missingDefaultDatabase

  /// A database ID was requested but has not been configured.
  case missingConfiguredDatabase(DatabaseID?)

  /// A fake database response could not be decoded to the requested type.
  case invalidFakeResponseType
}
