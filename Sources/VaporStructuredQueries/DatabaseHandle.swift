import Logging
import StructuredQueries

/// A database handle carrying an application- or request-scoped logger.
public struct DatabaseHandle: Database, Sendable {
  private let database: any Database

  /// The default logger for operations through this handle.
  public let logger: Logger

  public var migrationDialect: DatabaseMigrationDialect {
    self.database.migrationDialect
  }

  /// Creates a contextual handle around a database driver.
  public init(database: any Database, logger: Logger) {
    self.database = database
    self.logger = logger
  }

  public func stream<S: Statement>(
    _ statement: S,
    context: DatabaseExecutionContext
  ) async throws -> DatabaseRowStream<S.QueryValue.QueryOutput>
  where
    S.QueryValue: QueryRepresentable,
    S.QueryValue.QueryOutput: Sendable
  {
    try await self.database.stream(statement, context: context)
  }

  public func execute<S: Statement>(
    _ statement: S,
    context: DatabaseExecutionContext
  ) async throws -> DatabaseCommandMetadata?
  where S.QueryValue == () {
    try await self.database.execute(statement, context: context)
  }

  public func withConnection<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    try await self.database.withConnection(
      context: context,
      isolation: isolation
    ) { database in
      try await operation(DatabaseHandle(database: database, logger: context.logger))
    }
  }

  public func withTransaction<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    try await self.database.withTransaction(
      context: context,
      isolation: isolation
    ) { database in
      try await operation(DatabaseHandle(database: database, logger: context.logger))
    }
  }

  public func withMigrationLock<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    try await self.database.withMigrationLock(
      context: context,
      isolation: isolation
    ) { database in
      try await operation(DatabaseHandle(database: database, logger: context.logger))
    }
  }

  public func checkReadiness(
    context: DatabaseExecutionContext,
    timeout: Duration
  ) async throws {
    try await self.database.checkReadiness(context: context, timeout: timeout)
  }

  public func shutdown() async throws {
    try await self.database.shutdown()
  }
}
