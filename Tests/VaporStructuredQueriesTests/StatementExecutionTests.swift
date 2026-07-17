import Logging
import StructuredQueries
import Testing
import VaporStructuredQueries
import VaporStructuredQueriesTestSupport

struct StatementExecutionTests {
  @Test("execute(on:) forwards to database")
  func executeForwards() async throws {
    let database = FakeDatabase()

    try await #sql("SELECT \(bind: 1)", as: Void.self)
      .execute(on: database)

    let statements = database.recordedStatements()
    #expect(statements.count == 1)
    #expect(statements[0].sql == "SELECT ?")
    #expect(statements[0].bindCount == 1)
  }

  @Test("all(on:) decodes queued rows")
  func allForwards() async throws {
    let database = FakeDatabase()
    database.queueAll([1, 2, 3], forSQL: "SELECT ?")

    let rows = try await #sql("SELECT \(bind: 1)", as: Int.self)
      .all(on: database)

    #expect(rows == [1, 2, 3])
  }

  @Test("query representations need not be Sendable")
  func nonSendableQueryRepresentation() async throws {
    let database = FakeDatabase()
    database.queueAll([42], forSQL: "SELECT 42")

    let rows = try await #sql("SELECT 42", as: NonSendableIntRepresentation.self)
      .all(on: database)

    #expect(rows == [42])
  }

  @Test("first(on:) decodes queued row")
  func firstForwards() async throws {
    let database = FakeDatabase()
    database.queueFirst(42, forSQL: "SELECT ?")

    let row = try await #sql("SELECT \(bind: 1)", as: Int.self)
      .first(on: database)

    #expect(row == 42)
  }

  @Test("stream is typed and single-pass")
  func streamIsSinglePass() async throws {
    let database = FakeDatabase()
    database.queueAll([1, 2], forSQL: "SELECT ?")

    let stream = try await #sql("SELECT \(bind: 1)", as: Int.self)
      .stream(on: database)
    var iterator = stream.makeAsyncIterator()
    #expect(try await iterator.next() == 1)
    #expect(try await iterator.next() == 2)
    #expect(try await iterator.next() == nil)

    var secondIterator = stream.makeAsyncIterator()
    await #expect(throws: DatabaseRuntimeError.streamAlreadyConsumed) {
      _ = try await secondIterator.next()
    }
  }

  private final class NonSendableIntRepresentation: QueryRepresentable {
    var queryOutput: Int

    init(queryOutput: Int) {
      self.queryOutput = queryOutput
    }

    init(decoder: inout some QueryDecoder) throws {
      self.queryOutput = try Int(decoder: &decoder)
    }
  }

  @Test("execute returns truthful queued metadata")
  func executeMetadata() async throws {
    let database = FakeDatabase()
    database.queueMetadata(
      .init(command: "UPDATE", rowsAffected: 3),
      forSQL: "UPDATE widgets SET name = ?"
    )

    let metadata = try await #sql(
      "UPDATE widgets SET name = \(bind: "Blob")",
      as: Void.self
    )
    .execute(on: database)

    #expect(metadata == .init(command: "UPDATE", rowsAffected: 3))
  }

  @Test("caller logger and location are forwarded")
  func contextForwarding() async throws {
    let database = FakeDatabase()

    _ = try await #sql("SELECT 1", as: Void.self).execute(
      on: database,
      logger: Logger(label: "request-logger"),
      file: "Route.swift",
      line: 42
    )

    #expect(
      database.recordedContexts()
        == [.init(loggerLabel: "request-logger", file: "Route.swift", line: 42)]
    )
  }

  @Test("fake explicitly rejects atomic APIs")
  func unsupportedAtomicAPIs() async throws {
    let database = FakeDatabase()

    await #expect(throws: DatabaseRuntimeError.unsupportedOperation(.connection)) {
      try await database.withConnection { _ in () }
    }
    await #expect(throws: DatabaseRuntimeError.unsupportedOperation(.transaction)) {
      try await database.withTransaction { _ in () }
    }
  }

  @Test("fake readiness and shutdown are deterministic")
  func readinessAndShutdown() async throws {
    let database = FakeDatabase()
    try await database.checkReadiness()
    try await database.shutdown()
    try await database.shutdown()

    await #expect(throws: DatabaseRuntimeError.databaseShutdown) {
      _ = try await #sql("SELECT 1", as: Int.self).all(on: database)
    }
  }
}
