import Logging
import StructuredQueriesPostgresNIO
import VaporStructuredQueries

extension PostgresConnection {
  /// Borrows this connection for StructuredQueries execution without creating a pool.
  ///
  /// Statements run on this exact connection, including inside its current transaction.
  /// The caller must keep the connection open and its lease active for every operation.
  /// Do not return the adapter from a connection/transaction scope or cache it in an
  /// application database registry. It does not extend the connection's lease.
  ///
  /// Calling `shutdown()` is a no-op: only the owner releases or normally closes the
  /// connection. Cancellation still follows the native bridge's behavior, including
  /// closing the connection when a non-returning `execute` operation is cancelled.
  /// The owner remains responsible for transaction commit/rollback and cancellation cleanup.
  ///
  /// - Parameter logger: The logger forwarded to every operation on the connection.
  /// - Returns: A database adapter that borrows this connection.
  public func structuredQueries(logger: Logger) -> some VaporStructuredQueries.Database {
    BorrowedPostgresDatabase(connection: self, logger: logger)
  }
}

private struct BorrowedPostgresDatabase: VaporStructuredQueries.Database {
  let connection: PostgresConnection
  let logger: Logger

  func all<S: Statement>(_ statement: S) async throws -> [S.QueryValue.QueryOutput]
  where S.QueryValue: QueryRepresentable, S.QueryValue.QueryOutput: Sendable {
    let query = SQLQueryExpression(statement.query, as: DecodedValue<S.QueryValue>.self)
    var results: [S.QueryValue.QueryOutput] = []
    for try await row in try await self.connection.query(query, logger: self.logger) {
      results.append(row)
    }
    return results
  }

  func first<S: Statement>(_ statement: S) async throws -> S.QueryValue.QueryOutput?
  where S.QueryValue: QueryRepresentable, S.QueryValue.QueryOutput: Sendable {
    let query = SQLQueryExpression(statement.query, as: DecodedValue<S.QueryValue>.self)
    for try await row in try await self.connection.query(query, logger: self.logger) {
      return row
    }
    return nil
  }

  func execute(_ statement: some Statement<()>) async throws {
    _ = try await self.connection.execute(statement, logger: self.logger)
  }

  func shutdown() {}
}
