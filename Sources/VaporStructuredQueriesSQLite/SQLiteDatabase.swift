import Foundation
import Logging
import SQLite3
import StructuredQueriesSQLite
import VaporStructuredQueries

final class SQLiteDatabase: VaporStructuredQueries.Database, @unchecked Sendable {
  let logger: Logger
  let migrationDialect = DatabaseMigrationDialect.sqlite

  private let lock = NSLock()
  private let operationGate = SQLiteOperationGate()
  private var driver: SQLiteDriver?
  private let initializationError: Error?

  init(path: String, logger: Logger) {
    self.logger = logger
    do {
      self.driver = try SQLiteDriver(path: path)
      self.initializationError = nil
    } catch {
      self.driver = nil
      self.initializationError = error
    }
  }

  func stream<S: Statement>(
    _ statement: S,
    context: DatabaseExecutionContext
  ) async throws -> DatabaseRowStream<S.QueryValue.QueryOutput>
  where
    S.QueryValue: QueryRepresentable,
    S.QueryValue.QueryOutput: Sendable
  {
    let rows = try await self.withOperationGate {
      try self.withDriver { driver in
        try driver.execute(statement)
      }
    }
    return DatabaseRowStream(SQLiteRows(rows))
  }

  func execute<S: Statement>(
    _ statement: S,
    context: DatabaseExecutionContext
  ) async throws -> DatabaseCommandMetadata?
  where S.QueryValue == () {
    try await self.withOperationGate {
      try self.withDriver { driver in
        try driver.execute(statement)
      }
    }
    return nil
  }

  func withConnection<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    throw DatabaseRuntimeError.unsupportedOperation(.connection)
  }

  func withTransaction<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    throw DatabaseRuntimeError.unsupportedOperation(.transaction)
  }

  func withMigrationLock<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    let lease = try await self.operationGate.acquire()
    do {
      try await self.beginImmediate()
    } catch {
      await self.operationGate.release(lease)
      throw error
    }

    let validity = SQLiteMigrationHandleValidity()
    do {
      let result = try await operation(
        SQLiteMigrationDatabase(
          database: self,
          logger: context.logger,
          validity: validity
        )
      )
      try Task.checkCancellation()
      await validity.invalidateAndWait()
      try self.executeDirect("COMMIT")
      await self.operationGate.release(lease)
      return result
    } catch {
      await validity.invalidateAndWait()
      do {
        try self.executeDirect("ROLLBACK")
      } catch let rollbackError {
        self.invalidateDriver()
        await self.operationGate.release(lease)
        throw SQLiteMigrationRollbackError(
          operationError: String(reflecting: error),
          rollbackError: String(reflecting: rollbackError)
        )
      }
      await self.operationGate.release(lease)
      throw error
    }
  }

  func checkReadiness(
    context: DatabaseExecutionContext,
    timeout: Duration
  ) async throws {
    try await self.withOperationGate {
      try Task.checkCancellation()
      _ = try self.withDriver { driver in
        try driver.execute(#sql("SELECT 1", as: Int.self))
      }
      try Task.checkCancellation()
    }
  }

  func shutdown() async throws {
    try await self.withOperationGate {
      self.lock.withLock {
        self.driver = nil
      }
    }
  }

  private struct SQLiteRows<Element: Sendable>: AsyncSequence, Sendable {
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

  private func withDriver<T>(_ operation: (SQLiteDriver) throws -> T) throws -> T {
    self.lock.lock()
    defer { self.lock.unlock() }

    if let error = self.initializationError {
      throw error
    }
    guard let driver = self.driver else {
      throw SQLiteDatabaseError.connectionClosed
    }
    return try operation(driver)
  }

  fileprivate func streamDirect<S: Statement>(
    _ statement: S
  ) throws -> DatabaseRowStream<S.QueryValue.QueryOutput>
  where
    S.QueryValue: QueryRepresentable,
    S.QueryValue.QueryOutput: Sendable
  {
    let rows = try self.withDriver { try $0.execute(statement) }
    return DatabaseRowStream(SQLiteRows(rows))
  }

  fileprivate func executeDirect<S: Statement>(_ statement: S) throws
  where S.QueryValue == () {
    try self.withDriver { try $0.execute(statement) }
  }

  private func executeDirect(_ sql: String) throws {
    try self.withDriver { try $0.execute(sql) }
  }

  private func invalidateDriver() {
    self.lock.withLock {
      self.driver = nil
    }
  }

  private func beginImmediate() async throws {
    while true {
      try Task.checkCancellation()
      do {
        try self.executeDirect("BEGIN IMMEDIATE")
        return
      } catch let error as SQLiteError where error.isBusy {
        try await Task.sleep(for: .milliseconds(20))
      }
    }
  }

  private func withOperationGate<Result: Sendable>(
    _ operation: () throws -> Result
  ) async throws -> Result {
    let lease = try await self.operationGate.acquire()
    do {
      try Task.checkCancellation()
      let result = try operation()
      await self.operationGate.release(lease)
      return result
    } catch {
      await self.operationGate.release(lease)
      throw error
    }
  }
}

private enum SQLiteDatabaseError: Error {
  case connectionClosed
}

private struct SQLiteMigrationRollbackError: Error, Equatable, Sendable {
  let operationError: String
  let rollbackError: String
}

private actor SQLiteOperationGate {
  struct Lease: Equatable, Sendable {
    let id: UUID
  }

  private struct Waiter {
    let lease: Lease
    let continuation: CheckedContinuation<Void, any Error>
  }

  private var owner: Lease?
  private var waiters: [Waiter] = []

  func acquire() async throws -> Lease {
    let lease = Lease(id: UUID())
    try Task.checkCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if self.owner == nil {
          self.owner = lease
          continuation.resume()
        } else {
          self.waiters.append(Waiter(lease: lease, continuation: continuation))
        }
      }
      if Task.isCancelled {
        self.release(lease)
        throw CancellationError()
      }
    } onCancel: {
      Task { await self.cancel(lease) }
    }
    return lease
  }

  func release(_ lease: Lease) {
    guard self.owner == lease else { return }
    if self.waiters.isEmpty {
      self.owner = nil
    } else {
      let waiter = self.waiters.removeFirst()
      self.owner = waiter.lease
      waiter.continuation.resume()
    }
  }

  private func cancel(_ lease: Lease) {
    guard self.owner != lease else { return }
    guard let index = self.waiters.firstIndex(where: { $0.lease == lease }) else {
      return
    }
    let waiter = self.waiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }
}

private final class SQLiteMigrationHandleValidity: @unchecked Sendable {
  private struct State {
    var isValid = true
    var activeOperations = 0
    var drainContinuations: [CheckedContinuation<Void, Never>] = []
  }

  private let lock = NSLock()
  private var state = State()

  func beginOperation() throws -> SQLiteMigrationOperationLease {
    try self.lock.withLock {
      guard self.state.isValid else {
        throw DatabaseRuntimeError.borrowedConnectionExpired
      }
      self.state.activeOperations += 1
      return SQLiteMigrationOperationLease { [weak self] in
        self?.finishOperation()
      }
    }
  }

  func invalidateAndWait() async {
    self.lock.withLock {
      self.state.isValid = false
    }
    await withCheckedContinuation { continuation in
      let resumeImmediately = self.lock.withLock {
        if self.state.activeOperations == 0 {
          return true
        }
        self.state.drainContinuations.append(continuation)
        return false
      }
      if resumeImmediately {
        continuation.resume()
      }
    }
  }

  private func finishOperation() {
    let continuations = self.lock.withLock {
      () -> [CheckedContinuation<Void, Never>] in
      precondition(self.state.activeOperations > 0)
      self.state.activeOperations -= 1
      guard !self.state.isValid, self.state.activeOperations == 0 else {
        return []
      }
      let continuations = self.state.drainContinuations
      self.state.drainContinuations = []
      return continuations
    }
    for continuation in continuations {
      continuation.resume()
    }
  }
}

private final class SQLiteMigrationOperationLease: @unchecked Sendable {
  private let lock = NSLock()
  private var releaseOperation: (@Sendable () -> Void)?

  init(release: @escaping @Sendable () -> Void) {
    self.releaseOperation = release
  }

  func release() {
    let operation = self.lock.withLock {
      let operation = self.releaseOperation
      self.releaseOperation = nil
      return operation
    }
    operation?()
  }

  deinit {
    self.release()
  }
}

private final class SQLiteMigrationDatabase: VaporStructuredQueries.Database {
  let migrationDialect = DatabaseMigrationDialect.sqlite
  let logger: Logger

  private let database: SQLiteDatabase
  private let validity: SQLiteMigrationHandleValidity

  init(
    database: SQLiteDatabase,
    logger: Logger,
    validity: SQLiteMigrationHandleValidity
  ) {
    self.database = database
    self.logger = logger
    self.validity = validity
  }

  func stream<S: Statement>(
    _ statement: S,
    context: DatabaseExecutionContext
  ) async throws -> DatabaseRowStream<S.QueryValue.QueryOutput>
  where
    S.QueryValue: QueryRepresentable,
    S.QueryValue.QueryOutput: Sendable
  {
    let lease = try self.validity.beginOperation()
    defer { lease.release() }
    return try self.database.streamDirect(statement)
  }

  func execute<S: Statement>(
    _ statement: S,
    context: DatabaseExecutionContext
  ) async throws -> DatabaseCommandMetadata?
  where S.QueryValue == () {
    let lease = try self.validity.beginOperation()
    defer { lease.release() }
    try self.database.executeDirect(statement)
    return nil
  }

  func withConnection<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    let lease = try self.validity.beginOperation()
    defer { lease.release() }
    return try await operation(self)
  }

  func withTransaction<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    throw DatabaseRuntimeError.nestedTransactionUnsupported
  }

  func withMigrationLock<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    throw DatabaseRuntimeError.nestedTransactionUnsupported
  }

  func checkReadiness(
    context: DatabaseExecutionContext,
    timeout: Duration
  ) async throws {
    let lease = try self.validity.beginOperation()
    defer { lease.release() }
    try Task.checkCancellation()
    _ = try self.database.streamDirect(#sql("SELECT 1", as: Int.self))
  }

  func shutdown() async throws {
    throw DatabaseRuntimeError.unsupportedOperation(.shutdown)
  }
}

private struct SQLiteDriver {
  let storage: Storage

  init(_ ptr: OpaquePointer) {
    self.storage = .unowned(ptr)
  }

  init(path: String = ":memory:") throws {
    var handle: OpaquePointer?
    let code = sqlite3_open_v2(
      path,
      &handle,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
      nil
    )
    guard code == SQLITE_OK, let handle else { throw SQLiteError(code: code) }
    self.storage = .owned(Storage.Autoreleasing(handle))
  }

  func execute(_ sql: String) throws {
    guard sqlite3_exec(self.storage.handle, sql, nil, nil, nil) == SQLITE_OK
    else { throw SQLiteError(db: self.storage.handle) }
  }

  func execute(_ query: some Statement<()>) throws {
    let query = query.query
    guard !query.isEmpty else { return }
    try self.withStatement(query) { statement in
      loop: while true {
        let code = sqlite3_step(statement)
        switch code {
        case SQLITE_ROW:
          continue loop
        case SQLITE_DONE:
          break loop
        default:
          throw SQLiteError(db: self.storage.handle)
        }
      }
    }
  }

  func execute<QueryValue: QueryRepresentable>(
    _ query: some Statement<QueryValue>
  ) throws -> [QueryValue.QueryOutput] {
    let query = query.query
    guard !query.isEmpty else { return [] }
    return try self.withStatement(query) { statement in
      var results: [QueryValue.QueryOutput] = []
      var decoder = SQLiteQueryDecoder(statement: statement)
      loop: while true {
        let code = sqlite3_step(statement)
        switch code {
        case SQLITE_ROW:
          try results.append(decoder.decodeColumns(QueryValue.self))
          decoder.next()
        case SQLITE_DONE:
          break loop
        default:
          throw SQLiteError(db: self.storage.handle)
        }
      }
      return results
    }
  }

  func withStatement<R>(_ query: QueryFragment, body: (OpaquePointer) throws -> R) throws -> R {
    let (sql, bindings) = query.prepare { _ in "?" }
    var statement: OpaquePointer?
    let code = sqlite3_prepare_v2(self.storage.handle, sql, -1, &statement, nil)
    guard code == SQLITE_OK, let statement
    else { throw SQLiteError(db: self.storage.handle) }
    defer { sqlite3_finalize(statement) }
    for (index, binding) in zip(Int32(1)..., bindings) {
      let result =
        switch binding {
        case .blob(let blob):
          sqlite3_bind_blob(statement, index, Array(blob), Int32(blob.count), sqliteTransient)
        case .bool(let bool):
          sqlite3_bind_int64(statement, index, bool ? 1 : 0)
        case .date(let date):
          sqlite3_bind_text(statement, index, ISO8601Coding.string(from: date), -1, sqliteTransient)
        case .double(let double):
          sqlite3_bind_double(statement, index, double)
        case .int(let int):
          sqlite3_bind_int64(statement, index, Int64(int))
        case .null:
          sqlite3_bind_null(statement, index)
        case .text(let text):
          sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
        case .uint(let uint) where uint <= UInt64(Int64.max):
          sqlite3_bind_int64(statement, index, Int64(uint))
        case .uint(let uint):
          throw Int64OverflowError(unsignedInteger: uint)
        case .uuid(let uuid):
          sqlite3_bind_text(statement, index, uuid.uuidString.lowercased(), -1, sqliteTransient)
        case .invalid(let error):
          throw error.underlyingError
        }
      guard result == SQLITE_OK else { throw SQLiteError(db: self.storage.handle) }
    }
    return try body(statement)
  }

  enum Storage {
    case owned(Autoreleasing)
    case unowned(OpaquePointer)

    var handle: OpaquePointer {
      switch self {
      case .owned(let storage):
        storage.handle
      case .unowned(let handle):
        handle
      }
    }

    final class Autoreleasing {
      fileprivate var handle: OpaquePointer

      init(_ handle: OpaquePointer) {
        self.handle = handle
      }

      deinit {
        sqlite3_close_v2(self.handle)
      }
    }
  }
}

private struct SQLiteQueryDecoder: QueryDecoder {
  let statement: OpaquePointer
  var currentIndex: Int32 = 0

  init(statement: OpaquePointer) {
    self.statement = statement
  }

  mutating func next() {
    self.currentIndex = 0
  }

  mutating func decode(_ columnType: [UInt8].Type) throws -> [UInt8]? {
    defer { self.currentIndex += 1 }
    precondition(sqlite3_column_count(self.statement) > self.currentIndex)
    guard sqlite3_column_type(self.statement, self.currentIndex) != SQLITE_NULL else { return nil }
    return [UInt8](
      UnsafeRawBufferPointer(
        start: sqlite3_column_blob(self.statement, self.currentIndex),
        count: Int(sqlite3_column_bytes(self.statement, self.currentIndex))
      )
    )
  }

  mutating func decode(_ columnType: Bool.Type) throws -> Bool? {
    try self.decode(Int64.self).map { $0 != 0 }
  }

  mutating func decode(_ columnType: Date.Type) throws -> Date? {
    guard let iso8601String = try self.decode(String.self) else { return nil }
    guard let date = ISO8601Coding.date(from: iso8601String) else {
      throw SQLiteError(code: SQLITE_MISMATCH)
    }
    return date
  }

  mutating func decode(_ columnType: Double.Type) throws -> Double? {
    defer { self.currentIndex += 1 }
    precondition(sqlite3_column_count(self.statement) > self.currentIndex)
    guard sqlite3_column_type(self.statement, self.currentIndex) != SQLITE_NULL else { return nil }
    return sqlite3_column_double(self.statement, self.currentIndex)
  }

  mutating func decode(_ columnType: Int.Type) throws -> Int? {
    try self.decode(Int64.self).map(Int.init)
  }

  mutating func decode(_ columnType: Int64.Type) throws -> Int64? {
    defer { self.currentIndex += 1 }
    precondition(sqlite3_column_count(self.statement) > self.currentIndex)
    guard sqlite3_column_type(self.statement, self.currentIndex) != SQLITE_NULL else { return nil }
    return sqlite3_column_int64(self.statement, self.currentIndex)
  }

  mutating func decode(_ columnType: String.Type) throws -> String? {
    defer { self.currentIndex += 1 }
    precondition(sqlite3_column_count(self.statement) > self.currentIndex)
    guard sqlite3_column_type(self.statement, self.currentIndex) != SQLITE_NULL else { return nil }
    return String(cString: sqlite3_column_text(self.statement, self.currentIndex))
  }

  mutating func decode(_ columnType: UInt64.Type) throws -> UInt64? {
    guard let n = try self.decode(Int64.self) else { return nil }
    guard n >= 0 else { throw UInt64OverflowError(signedInteger: n) }
    return UInt64(n)
  }

  mutating func decode(_ columnType: UUID.Type) throws -> UUID? {
    guard let uuidString = try self.decode(String.self) else { return nil }
    return UUID(uuidString: uuidString)
  }
}

private struct UInt64OverflowError: Error {
  let signedInteger: Int64
}

private struct Int64OverflowError: Error {
  let unsignedInteger: UInt64
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct SQLiteError: LocalizedError {
  let code: Int32
  let message: String

  init(db handle: OpaquePointer?) {
    self.code = sqlite3_extended_errcode(handle)
    self.message = String(cString: sqlite3_errmsg(handle))
  }

  init(code: Int32) {
    self.code = code
    self.message = String(cString: sqlite3_errstr(code))
  }

  var isBusy: Bool {
    self.code == SQLITE_BUSY || self.code == SQLITE_LOCKED
      || self.code & 0xFF == SQLITE_BUSY || self.code & 0xFF == SQLITE_LOCKED
  }

  var errorDescription: String? {
    self.message
  }
}

private enum ISO8601Coding {
  static func string(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  static func date(from string: String) -> Date? {
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: string) {
      return date
    }

    let withoutFractional = ISO8601DateFormatter()
    withoutFractional.formatOptions = [.withInternetDateTime]
    return withoutFractional.date(from: string)
  }
}
