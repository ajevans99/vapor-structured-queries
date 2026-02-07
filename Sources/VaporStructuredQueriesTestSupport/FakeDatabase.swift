import NIOConcurrencyHelpers
import StructuredQueries
import VaporStructuredQueries

/// A configurable in-memory database implementation for unit testing.
public final class FakeDatabase: @unchecked Sendable, Database {
  private struct StoredValue: @unchecked Sendable {
    let base: Any?
  }

  private struct Storage {
    var recordedStatements: [RecordedStatement] = []
    var allResponses: [String: [StoredValue]] = [:]
    var firstResponses: [String: StoredValue] = [:]
  }

  private let storage = NIOLockedValueBox(Storage())

  /// Creates an empty fake database.
  public init() {}

  /// Enqueues rows returned by ``all(_:)`` for a prepared SQL string.
  ///
  /// - Parameters:
  ///   - rows: Rows to return.
  ///   - sql: Prepared SQL key using `?` placeholders.
  public func queueAll<T: Sendable>(_ rows: [T], forSQL sql: String) {
    self.storage.withLockedValue { storage in
      storage.allResponses[sql] = rows.map { StoredValue(base: $0) }
    }
  }

  /// Enqueues a row returned by ``first(_:)`` for a prepared SQL string.
  ///
  /// - Parameters:
  ///   - row: Row to return.
  ///   - sql: Prepared SQL key using `?` placeholders.
  public func queueFirst<T: Sendable>(_ row: T?, forSQL sql: String) {
    self.storage.withLockedValue { storage in
      storage.firstResponses[sql] = StoredValue(base: row)
    }
  }

  /// Returns statements that have been executed.
  public func recordedStatements() -> [RecordedStatement] {
    self.storage.withLockedValue { $0.recordedStatements }
  }

  /// Clears queued responses and recorded statements.
  public func reset() {
    self.storage.withLockedValue { storage in
      storage = Storage()
    }
  }

  public func all<S: Statement>(_ statement: S) async throws -> [S.QueryValue.QueryOutput]
  where S.QueryValue: QueryRepresentable, S.QueryValue.QueryOutput: Sendable {
    let recorded = RecordedStatement(query: statement.query)
    return try self.storage.withLockedValue { storage in
      storage.recordedStatements.append(recorded)
      let values = storage.allResponses[recorded.sql] ?? []
      return try values.map { storedValue in
        guard let value = storedValue.base as? S.QueryValue.QueryOutput else {
          throw DatabaseRuntimeError.invalidFakeResponseType
        }
        return value
      }
    }
  }

  public func first<S: Statement>(_ statement: S) async throws -> S.QueryValue.QueryOutput?
  where S.QueryValue: QueryRepresentable, S.QueryValue.QueryOutput: Sendable {
    let recorded = RecordedStatement(query: statement.query)
    return try self.storage.withLockedValue { storage in
      storage.recordedStatements.append(recorded)

      if let value = storage.firstResponses[recorded.sql]?.base {
        guard let typed = value as? S.QueryValue.QueryOutput else {
          throw DatabaseRuntimeError.invalidFakeResponseType
        }
        return typed
      }

      if let first = storage.allResponses[recorded.sql]?.first?.base {
        guard let typed = first as? S.QueryValue.QueryOutput else {
          throw DatabaseRuntimeError.invalidFakeResponseType
        }
        return typed
      }

      return nil
    }
  }

  public func execute(_ statement: some Statement<()>) async throws {
    let recorded = RecordedStatement(query: statement.query)
    self.storage.withLockedValue { storage in
      storage.recordedStatements.append(recorded)
    }
  }

  public func shutdown() {}
}
