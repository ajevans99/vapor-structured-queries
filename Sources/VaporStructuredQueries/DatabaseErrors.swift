/// Errors produced by the VaporStructuredQueries runtime.
public enum DatabaseRuntimeError: Error, Equatable, Sendable {
  /// No default database has been configured.
  case missingDefaultDatabase

  /// A database ID was requested but has not been configured.
  case missingConfiguredDatabase(DatabaseID?)

  /// A fake database response could not be decoded to the requested type.
  case invalidFakeResponseType

  /// An operation is not supported by a database driver or handle.
  case unsupportedOperation(DatabaseOperation)

  /// A transaction was requested from an already transaction-bound handle.
  case nestedTransactionUnsupported

  /// A leased connection handle was used after its operation ended.
  case borrowedConnectionExpired

  /// A second iterator was requested from a single-pass row stream.
  case streamAlreadyConsumed

  /// Readiness did not complete within its timeout.
  case readinessTimedOut

  /// The database is draining and rejects new work.
  case databaseShuttingDown

  /// The database has completed shutdown.
  case databaseShutdown

  /// A database configuration field is invalid.
  case invalidConfiguration(field: String)
}

/// Operations that a database driver may explicitly not support.
public enum DatabaseOperation: String, Equatable, Sendable {
  /// Leasing a dedicated connection.
  case connection

  /// Running a transaction.
  case transaction

  /// Serializing and atomically running database migrations.
  case migrationLock

  /// Checking readiness.
  case readiness

  /// Shutting down a non-owning database handle.
  case shutdown
}
