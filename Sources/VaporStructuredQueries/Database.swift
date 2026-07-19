import Logging
import StructuredQueries

/// A runtime database capable of executing StructuredQueries statements.
public protocol Database: Sendable {
  /// The migration schema dialect supported by this database.
  var migrationDialect: DatabaseMigrationDialect { get }

  /// The default logger for operations on this database handle.
  var logger: Logger { get }

  /// Streams rows decoded from a statement.
  ///
  /// - Parameters:
  ///   - statement: The statement to execute.
  ///   - context: The logger and source location for the operation.
  /// - Returns: A single-pass row stream.
  /// - Throws: An error if execution or decoding fails.
  func stream<S: Statement>(
    _ statement: S,
    context: DatabaseExecutionContext
  ) async throws -> DatabaseRowStream<S.QueryValue.QueryOutput>
  where
    S.QueryValue: QueryRepresentable,
    S.QueryValue.QueryOutput: Sendable

  /// Executes a statement that does not return row data.
  ///
  /// - Parameters:
  ///   - statement: The statement to execute.
  ///   - context: The logger and source location for the operation.
  /// - Returns: Truthful command metadata when the driver provides it.
  /// - Throws: An error if execution fails.
  func execute<S: Statement>(
    _ statement: S,
    context: DatabaseExecutionContext
  ) async throws -> DatabaseCommandMetadata?
  where S.QueryValue == ()

  /// Leases one database connection for an operation.
  func withConnection<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result

  /// Runs an operation atomically on one database connection.
  func withTransaction<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result

  /// Serializes and atomically executes migration work.
  func withMigrationLock<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result

  /// Verifies that the database can serve queries within a timeout.
  func checkReadiness(
    context: DatabaseExecutionContext,
    timeout: Duration
  ) async throws

  /// Gracefully and idempotently shuts down resources held by this database.
  func shutdown() async throws
}

/// Context forwarded to a database operation.
public struct DatabaseExecutionContext: Sendable {
  /// The operation logger.
  public var logger: Logger

  /// The caller's source file.
  public var file: String

  /// The caller's source line.
  public var line: Int

  /// Creates an execution context.
  public init(logger: Logger, file: String, line: Int) {
    self.logger = logger
    self.file = file
    self.line = line
  }
}

/// Portable metadata for a completed non-returning statement.
public struct DatabaseCommandMetadata: Equatable, Sendable {
  /// The command reported by the database, when available.
  public var command: String?

  /// The affected row count reported by the database, when available.
  public var rowsAffected: Int?

  /// Creates command metadata.
  public init(command: String? = nil, rowsAffected: Int? = nil) {
    self.command = command
    self.rowsAffected = rowsAffected
  }
}

/// SQL schema behavior available to the migration runtime.
public enum DatabaseMigrationDialect: String, Equatable, Sendable {
  /// The driver has not implemented production-safe migrations.
  case unsupported

  /// PostgreSQL migration schema behavior.
  case postgres

  /// SQLite migration schema behavior.
  case sqlite
}

extension Database {
  public var migrationDialect: DatabaseMigrationDialect {
    .unsupported
  }

  public func withMigrationLock<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    throw DatabaseRuntimeError.unsupportedOperation(.migrationLock)
  }

  /// Streams rows decoded from a statement.
  public func stream<S: Statement>(
    _ statement: S,
    logger: Logger? = nil,
    file: String = #fileID,
    line: Int = #line
  ) async throws -> DatabaseRowStream<S.QueryValue.QueryOutput>
  where
    S.QueryValue: QueryRepresentable,
    S.QueryValue.QueryOutput: Sendable
  {
    try await self.stream(
      statement,
      context: .init(logger: logger ?? self.logger, file: file, line: line)
    )
  }

  /// Executes a statement and decodes all rows.
  public func all<S: Statement>(
    _ statement: S,
    logger: Logger? = nil,
    file: String = #fileID,
    line: Int = #line
  ) async throws -> [S.QueryValue.QueryOutput]
  where
    S.QueryValue: QueryRepresentable,
    S.QueryValue.QueryOutput: Sendable
  {
    var rows: [S.QueryValue.QueryOutput] = []
    for try await row in try await self.stream(
      statement,
      logger: logger,
      file: file,
      line: line
    ) {
      rows.append(row)
    }
    return rows
  }

  /// Executes a statement and decodes its first row.
  public func first<S: Statement>(
    _ statement: S,
    logger: Logger? = nil,
    file: String = #fileID,
    line: Int = #line
  ) async throws -> S.QueryValue.QueryOutput?
  where
    S.QueryValue: QueryRepresentable,
    S.QueryValue.QueryOutput: Sendable
  {
    for try await row in try await self.stream(
      statement,
      logger: logger,
      file: file,
      line: line
    ) {
      return row
    }
    return nil
  }

  /// Executes a statement that does not return row data.
  @discardableResult
  public func execute<S: Statement>(
    _ statement: S,
    logger: Logger? = nil,
    file: String = #fileID,
    line: Int = #line
  ) async throws -> DatabaseCommandMetadata?
  where S.QueryValue == () {
    try await self.execute(
      statement,
      context: .init(logger: logger ?? self.logger, file: file, line: line)
    )
  }

  /// Leases one database connection for an operation.
  public func withConnection<Result: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    logger: Logger? = nil,
    file: String = #fileID,
    line: Int = #line,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    try await self.withConnection(
      context: .init(logger: logger ?? self.logger, file: file, line: line),
      isolation: isolation,
      operation
    )
  }

  /// Runs an operation atomically on one database connection.
  public func withTransaction<Result: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    logger: Logger? = nil,
    file: String = #fileID,
    line: Int = #line,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    try await self.withTransaction(
      context: .init(logger: logger ?? self.logger, file: file, line: line),
      isolation: isolation,
      operation
    )
  }

  /// Serializes migration runners and runs an operation atomically.
  ///
  /// Drivers must only implement this operation when the serialization spans
  /// independent application processes targeting the same database.
  public func withMigrationLock<Result: Sendable>(
    isolation: isolated (any Actor)? = #isolation,
    logger: Logger? = nil,
    file: String = #fileID,
    line: Int = #line,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    try await self.withMigrationLock(
      context: .init(logger: logger ?? self.logger, file: file, line: line),
      isolation: isolation,
      operation
    )
  }

  /// Verifies that the database can serve queries within a timeout.
  public func checkReadiness(
    timeout: Duration = .seconds(2),
    logger: Logger? = nil,
    file: String = #fileID,
    line: Int = #line
  ) async throws {
    try await self.checkReadiness(
      context: .init(logger: logger ?? self.logger, file: file, line: line),
      timeout: timeout
    )
  }
}
