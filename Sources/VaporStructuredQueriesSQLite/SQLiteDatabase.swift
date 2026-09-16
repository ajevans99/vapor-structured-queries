import Foundation
import StructuredQueriesSQLite
import VaporStructuredQueries
import VaporStructuredQueriesCSQLite

final class SQLiteDatabase: VaporStructuredQueries.Database, @unchecked Sendable {
  private let lock = NSLock()
  private var driver: SQLiteDriver?
  private let initializationError: Error?

  init(path: String) {
    do {
      self.driver = try SQLiteDriver(path: path)
      self.initializationError = nil
    } catch {
      self.driver = nil
      self.initializationError = error
    }
  }

  func all<S: Statement>(_ statement: S) async throws -> [S.QueryValue.QueryOutput]
  where S.QueryValue: QueryRepresentable, S.QueryValue.QueryOutput: Sendable {
    try self.withDriver { driver in
      try driver.execute(statement)
    }
  }

  func first<S: Statement>(_ statement: S) async throws -> S.QueryValue.QueryOutput?
  where S.QueryValue: QueryRepresentable, S.QueryValue.QueryOutput: Sendable {
    try self.withDriver { driver in
      try driver.execute(statement).first
    }
  }

  func execute(_ statement: some Statement<()>) async throws {
    try self.withDriver { driver in
      try driver.execute(statement)
    }
  }

  func shutdown() {
    self.lock.lock()
    self.driver = nil
    self.lock.unlock()
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
}

private enum SQLiteDatabaseError: Error {
  case connectionClosed
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
  let message: String

  init(db handle: OpaquePointer?) {
    self.message = String(cString: sqlite3_errmsg(handle))
  }

  init(code: Int32) {
    self.message = String(cString: sqlite3_errstr(code))
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
