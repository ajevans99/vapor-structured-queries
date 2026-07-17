import Foundation
import Logging
import StructuredQueries
import Testing
import VaporStructuredQueries
import VaporStructuredQueriesPostgresNIO
import VaporTesting

@Suite(.serialized)
struct PostgresIntegrationTests {
  @Test("typed streaming, metadata, and caller context")
  func streamingMetadataAndContext() async throws {
    try await withPostgresApp { app in
      let database = app.db
      try await resetRuntimeTable(on: database)

      let insert = try #require(
        try await #sql(
          """
          INSERT INTO "vsq_runtime_test" ("id", "value")
          VALUES (\(bind: 1), \(bind: "Blob")), (\(bind: 2), \(bind: "Blob Jr."))
          """,
          as: Void.self
        )
        .execute(on: database)
      )
      #expect(insert.command == "INSERT")
      #expect(insert.rowsAffected == 2)

      let stream = try await #sql(
        "SELECT \"id\" FROM \"vsq_runtime_test\" ORDER BY \"id\"",
        as: Int.self
      )
      .stream(on: database)
      var iterator = stream.makeAsyncIterator()
      #expect(try await iterator.next() == 1)
      #expect(try await iterator.next() == 2)
      #expect(try await iterator.next() == nil)
      #expect(
        try await #sql("SELECT 42", as: NonSendablePostgresIntRepresentation.self)
          .first(on: database) == 42
      )

      do {
        _ = try await #sql(
          """
          INSERT INTO "vsq_runtime_test" ("id", "value")
          VALUES (\(bind: 1), \(bind: "Duplicate"))
          """,
          as: Void.self
        )
        .execute(
          on: database,
          logger: Logger(label: "request-specific-logger"),
          file: "RequestRoute.swift",
          line: 123
        )
        Issue.record("Expected a unique constraint failure")
      } catch let error as PSQLError {
        #expect(error.file == "RequestRoute.swift")
        #expect(error.line == 123)
        #expect(error.serverInfo?[.sqlState] == "23505")
      }
    }
  }

  @Test("connection affinity and transaction commit and rollback")
  func transactionsAndAffinity() async throws {
    try await withPostgresApp { app in
      let database = app.db
      try await resetRuntimeTable(on: database)

      let connectionPID = try await database.withConnection { connection in
        let first = try #require(
          try await #sql("SELECT pg_backend_pid()", as: Int.self).first(on: connection)
        )
        let nested = try await connection.withConnection { sameConnection in
          try #require(
            try await #sql("SELECT pg_backend_pid()", as: Int.self).first(on: sameConnection)
          )
        }
        #expect(first == nested)

        try await connection.withTransaction { transaction in
          _ = try await #sql(
            """
            INSERT INTO "vsq_runtime_test" ("id", "value")
            VALUES (\(bind: 1), \(bind: "Committed"))
            """,
            as: Void.self
          )
          .execute(on: transaction)

          let transactionPID = try #require(
            try await #sql("SELECT pg_backend_pid()", as: Int.self).first(on: transaction)
          )
          #expect(transactionPID == first)

          let reusedPID = try await transaction.withConnection { sameTransaction in
            try #require(
              try await #sql("SELECT pg_backend_pid()", as: Int.self).first(
                on: sameTransaction
              )
            )
          }
          #expect(reusedPID == first)

          await #expect(throws: DatabaseRuntimeError.nestedTransactionUnsupported) {
            try await transaction.withTransaction { _ in () }
          }
        }
        return first
      }
      #expect(connectionPID > 0)
      #expect(try await rowCount(on: database) == 1)

      let escapedHandle = try await database.withConnection { connection in
        connection
      }
      await #expect(throws: DatabaseRuntimeError.borrowedConnectionExpired) {
        _ = try await #sql("SELECT 1", as: Int.self).first(on: escapedHandle)
      }

      let escapedStream = try await database.withConnection { connection in
        try await #sql("SELECT generate_series(1, 10)", as: Int.self).stream(
          on: connection
        )
      }
      var escapedIterator = escapedStream.makeAsyncIterator()
      await #expect(throws: (any Error).self) {
        _ = try await escapedIterator.next()
      }
      #expect(try await #sql("SELECT 7", as: Int.self).first(on: database) == 7)

      do {
        try await database.withTransaction { transaction in
          _ = try await #sql(
            """
            INSERT INTO "vsq_runtime_test" ("id", "value")
            VALUES (\(bind: 2), \(bind: "Rolled back"))
            """,
            as: Void.self
          )
          .execute(on: transaction)
          throw Rollback()
        }
        Issue.record("Expected the transaction to roll back")
      } catch let error as PostgresTransactionError {
        #expect(error.closureError is Rollback)
      }
      #expect(try await rowCount(on: database) == 1)
    }
  }

  @Test("early termination, decode failure, and cancellation release the pool")
  func streamAndCancellationRelease() async throws {
    try await withPostgresApp(maximumConnections: 1) { app in
      let database = app.db

      do {
        let stream = try await #sql(
          "SELECT generate_series(1, 10000)",
          as: Int.self
        )
        .stream(on: database)
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == 1)
      }
      #expect(
        try await #sql("SELECT 2", as: Int.self).first(on: database) == 2
      )

      do {
        _ = try await #sql("SELECT 3", as: Int.self).stream(on: database)
      }
      #expect(
        try await #sql("SELECT 4", as: Int.self).first(on: database) == 4
      )

      do {
        let stream = try await #sql(
          "SELECT 'not-an-integer'",
          as: Int.self
        )
        .stream(on: database)
        var iterator = stream.makeAsyncIterator()
        await #expect(throws: (any Error).self) {
          _ = try await iterator.next()
        }
      }
      #expect(
        try await #sql("SELECT 5", as: Int.self).first(on: database) == 5
      )

      let task = Task {
        try await #sql("SELECT pg_sleep(10)", as: Void.self).execute(on: database)
      }
      try await Task.sleep(for: .milliseconds(100))
      task.cancel()
      await #expect(throws: CancellationError.self) {
        _ = try await task.value
      }
      #expect(
        try await #sql("SELECT 6", as: Int.self).first(on: database) == 6
      )
    }
  }

  @Test("readiness is bounded and concurrent operations succeed")
  func readinessAndConcurrency() async throws {
    try await withPostgresApp(maximumConnections: 4) { app in
      let database = app.db
      try await database.checkReadiness(timeout: .seconds(2))

      let values = try await withThrowingTaskGroup(of: Int.self) { group in
        for value in 0..<20 {
          group.addTask {
            try #require(
              try await #sql("SELECT \(bind: value)", as: Int.self).first(on: database)
            )
          }
        }
        var values: [Int] = []
        for try await value in group {
          values.append(value)
        }
        return values.sorted()
      }
      #expect(values == Array(0..<20))
    }

    try await withPostgresApp(maximumConnections: 1) { app in
      let database = app.db
      let holder = Task {
        try await database.withConnection { connection in
          _ = try await #sql("SELECT pg_sleep(0.5)", as: Void.self).execute(on: connection)
        }
      }
      try await Task.sleep(for: .milliseconds(100))
      await #expect(throws: DatabaseRuntimeError.readinessTimedOut) {
        try await database.checkReadiness(timeout: .milliseconds(100))
      }
      try await holder.value
      try await database.checkReadiness(timeout: .seconds(2))
    }
  }

  @Test("shutdown drains work and is idempotent")
  func gracefulShutdown() async throws {
    try await withPostgresApp(maximumConnections: 1) { app in
      let database = app.db
      let clock = ContinuousClock()
      let operation = Task {
        try await #sql("SELECT pg_sleep(0.5)", as: Void.self).execute(on: database)
      }
      try await Task.sleep(for: .milliseconds(100))

      let start = clock.now
      async let firstShutdown: Void = database.shutdown()
      async let secondShutdown: Void = database.shutdown()
      _ = try await (firstShutdown, secondShutdown)
      #expect(start.duration(to: clock.now) >= .milliseconds(250))
      _ = try await operation.value

      try await database.shutdown()
      await #expect(throws: DatabaseRuntimeError.databaseShutdown) {
        _ = try await #sql("SELECT 1", as: Int.self).first(on: database)
      }
    }
  }
}

private struct Rollback: Error {}
private struct MissingPostgresConfiguration: Error {}

private final class NonSendablePostgresIntRepresentation: QueryRepresentable {
  var queryOutput: Int

  init(queryOutput: Int) {
    self.queryOutput = queryOutput
  }

  init(decoder: inout some QueryDecoder) throws {
    self.queryOutput = try Int(decoder: &decoder)
  }
}

private struct PostgresLiveConfiguration: Sendable {
  let host: String
  let port: Int
  let username: String
  let password: String?
  let database: String

  init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
    guard
      let host = environment["POSTGRES_HOST"],
      let username = environment["POSTGRES_USER"],
      let database = environment["POSTGRES_DB"]
    else {
      throw MissingPostgresConfiguration()
    }
    self.host = host
    self.port = Int(environment["POSTGRES_PORT"] ?? "") ?? 5432
    self.username = username
    self.password = environment["POSTGRES_PASSWORD"]
    self.database = database
  }
}

private func withPostgresApp<Result: Sendable>(
  maximumConnections: Int = 4,
  _ operation: (Application) async throws -> sending Result
) async throws -> sending Result {
  let live = try PostgresLiveConfiguration()
  var options = PostgresClient.Configuration.Options()
  options.minimumConnections = 0
  options.maximumConnections = maximumConnections
  return try await withApp { app in
    try await app.database.use(
      try .postgresInsecureForLocalDevelopment(
        hostname: live.host,
        port: live.port,
        username: live.username,
        password: live.password,
        database: live.database,
        options: options
      ),
      as: .psql
    )
    app.database.default(to: .psql)
    return try await operation(app)
  }
}

private func resetRuntimeTable(on database: any Database) async throws {
  _ = try await #sql(
    "DROP TABLE IF EXISTS \"vsq_runtime_test\"",
    as: Void.self
  )
  .execute(on: database)
  _ = try await #sql(
    """
    CREATE TABLE "vsq_runtime_test" (
      "id" BIGINT PRIMARY KEY,
      "value" TEXT NOT NULL
    )
    """,
    as: Void.self
  )
  .execute(on: database)
}

private func rowCount(on database: any Database) async throws -> Int {
  try #require(
    try await #sql(
      "SELECT COUNT(*) FROM \"vsq_runtime_test\"",
      as: Int.self
    )
    .first(on: database)
  )
}
