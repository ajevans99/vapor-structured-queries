import Logging
import NIOConcurrencyHelpers
import StructuredQueries
import VaporStructuredQueries

/// A configurable in-memory database recorder for unit testing.
public final class FakeDatabase: Database {
  private protocol StoredValue: Sendable {
    func decode<Value: Sendable>(as type: Value.Type) throws -> Value
  }

  private struct ValueBox<Value: Sendable>: StoredValue {
    let value: Value

    func decode<Decoded: Sendable>(as type: Decoded.Type) throws -> Decoded {
      guard let decoded = self.value as? Decoded else {
        throw DatabaseRuntimeError.invalidFakeResponseType
      }
      return decoded
    }
  }

  private enum FirstResponse: Sendable {
    case none
    case value(any StoredValue)
  }

  private struct Storage: Sendable {
    var recordedStatements: [RecordedStatement] = []
    var recordedContexts: [RecordedDatabaseContext] = []
    var allResponses: [String: [any StoredValue]] = [:]
    var firstResponses: [String: FirstResponse] = [:]
    var metadataResponses: [String: DatabaseCommandMetadata?] = [:]
    var readinessError: (any Error)?
    var shutdownError: (any Error)?
    var shutdownCallCount = 0
    var isShutdown = false
  }

  private let storage = NIOLockedValueBox(Storage())

  /// The default logger for fake operations.
  public let logger: Logger

  /// Creates an empty fake database.
  public init(logger: Logger = Logger(label: "VaporStructuredQueriesTestSupport.FakeDatabase")) {
    self.logger = logger
  }

  /// Enqueues rows returned by a read for a prepared SQL string.
  public func queueAll<T: Sendable>(_ rows: [T], forSQL sql: String) {
    self.storage.withLockedValue { storage in
      storage.allResponses[sql] = rows.map(ValueBox.init)
    }
  }

  /// Enqueues a row returned by a read for a prepared SQL string.
  public func queueFirst<T: Sendable>(_ row: T?, forSQL sql: String) {
    self.storage.withLockedValue { storage in
      storage.firstResponses[sql] = row.map { .value(ValueBox(value: $0)) } ?? .none
    }
  }

  /// Enqueues command metadata for a prepared SQL string.
  public func queueMetadata(
    _ metadata: DatabaseCommandMetadata?,
    forSQL sql: String
  ) {
    self.storage.withLockedValue { storage in
      storage.metadataResponses[sql] = metadata
    }
  }

  /// Configures an error for subsequent readiness checks.
  public func setReadinessError(_ error: (any Error)?) {
    self.storage.withLockedValue { storage in
      storage.readinessError = error
    }
  }

  /// Configures an error for subsequent shutdown calls.
  public func setShutdownError(_ error: (any Error)?) {
    self.storage.withLockedValue { storage in
      storage.shutdownError = error
    }
  }

  /// Returns the number of shutdown calls.
  public func shutdownCallCount() -> Int {
    self.storage.withLockedValue(\.shutdownCallCount)
  }

  /// Returns statements that have been executed.
  public func recordedStatements() -> [RecordedStatement] {
    self.storage.withLockedValue { $0.recordedStatements }
  }

  /// Returns contexts forwarded to fake operations.
  public func recordedContexts() -> [RecordedDatabaseContext] {
    self.storage.withLockedValue { $0.recordedContexts }
  }

  /// Clears queued responses and recorded statements.
  public func reset() {
    self.storage.withLockedValue { storage in
      storage = Storage()
    }
  }

  public func stream<S: Statement>(
    _ statement: S,
    context: DatabaseExecutionContext
  ) async throws -> DatabaseRowStream<S.QueryValue.QueryOutput>
  where
    S.QueryValue: QueryRepresentable,
    S.QueryValue.QueryOutput: Sendable
  {
    let recorded = RecordedStatement(query: statement.query)
    let rows: [S.QueryValue.QueryOutput] = try self.storage.withLockedValue { storage in
      try Self.checkAvailable(storage)
      storage.recordedStatements.append(recorded)
      storage.recordedContexts.append(RecordedDatabaseContext(context))
      if let values = storage.allResponses[recorded.sql] {
        return try values.map { try $0.decode(as: S.QueryValue.QueryOutput.self) }
      }
      switch storage.firstResponses[recorded.sql] {
      case .value(let value):
        return [try value.decode(as: S.QueryValue.QueryOutput.self)]
      case .some(.none), nil:
        return []
      }
    }
    return DatabaseRowStream(FakeRows(rows))
  }

  public func execute<S: Statement>(
    _ statement: S,
    context: DatabaseExecutionContext
  ) async throws -> DatabaseCommandMetadata?
  where S.QueryValue == () {
    let recorded = RecordedStatement(query: statement.query)
    return try self.storage.withLockedValue { storage in
      try Self.checkAvailable(storage)
      storage.recordedStatements.append(recorded)
      storage.recordedContexts.append(RecordedDatabaseContext(context))
      return storage.metadataResponses[recorded.sql] ?? nil
    }
  }

  public func withConnection<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    throw DatabaseRuntimeError.unsupportedOperation(.connection)
  }

  public func withTransaction<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    throw DatabaseRuntimeError.unsupportedOperation(.transaction)
  }

  public func checkReadiness(
    context: DatabaseExecutionContext,
    timeout: Duration
  ) async throws {
    try Task.checkCancellation()
    let error = try self.storage.withLockedValue { storage in
      try Self.checkAvailable(storage)
      storage.recordedContexts.append(RecordedDatabaseContext(context))
      return storage.readinessError
    }

    if let error {
      throw error
    }
  }

  public func shutdown() async throws {
    let error = self.storage.withLockedValue { storage in
      storage.shutdownCallCount += 1
      storage.isShutdown = true
      return storage.shutdownError
    }
    if let error {
      throw error
    }
  }

  private static func checkAvailable(_ storage: Storage) throws {
    if storage.isShutdown {
      throw DatabaseRuntimeError.databaseShutdown
    }
  }
}

/// Logger and source information recorded by a fake operation.
public struct RecordedDatabaseContext: Equatable, Sendable {
  /// The logger label.
  public let loggerLabel: String

  /// The caller's source file.
  public let file: String

  /// The caller's source line.
  public let line: Int

  /// Creates a recorded context.
  public init(loggerLabel: String, file: String, line: Int) {
    self.loggerLabel = loggerLabel
    self.file = file
    self.line = line
  }

  init(_ context: DatabaseExecutionContext) {
    self.init(
      loggerLabel: context.logger.label,
      file: context.file,
      line: context.line
    )
  }
}

private struct FakeRows<Element: Sendable>: AsyncSequence, Sendable {
  let elements: [Element]

  init(_ elements: [Element]) {
    self.elements = elements
  }

  struct AsyncIterator: AsyncIteratorProtocol {
    var iterator: IndexingIterator<[Element]>

    mutating func next() async -> Element? {
      self.iterator.next()
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(iterator: self.elements.makeIterator())
  }
}
