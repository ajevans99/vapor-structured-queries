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

  @Test("migration prepare and bookkeeping roll back atomically")
  func migrationPrepareRollback() async throws {
    try await withPostgresApp { app in
      try await resetMigrationFixtures(on: app.db)
      try await app.db.execute(
        #sql(
          """
          CREATE TABLE "_database_migrations" (
            "name" TEXT PRIMARY KEY,
            "batch" BIGINT NOT NULL,
            "sequence" BIGINT,
            CHECK ("name" <> 'atomic-prepare')
          )
          """,
          as: Void.self
        )
      )
      app.migrations.add(CreateMigrationFixture(name: "atomic-prepare"))

      await #expect(throws: (any Error).self) {
        try await app.autoMigrate()
      }
      #expect(try await relationExists("vsq_migration_fixture", on: app.db) == false)
      #expect(try await migrationRecordCount(on: app.db) == 0)
    }
  }

  @Test("migration revert and bookkeeping roll back atomically")
  func migrationRevertRollback() async throws {
    try await withPostgresApp { app in
      try await resetMigrationFixtures(on: app.db)
      app.migrations.add(CreateMigrationFixture(name: "atomic-revert"))
      try await app.autoMigrate()
      try await app.db.execute(
        #sql(
          """
          CREATE TABLE "vsq_migration_guard" (
            "name" TEXT REFERENCES "_database_migrations" ("name")
          )
          """,
          as: Void.self
        )
      )
      try await app.db.execute(
        #sql(
          """
          INSERT INTO "vsq_migration_guard" ("name")
          VALUES ('atomic-revert')
          """,
          as: Void.self
        )
      )

      await #expect(throws: (any Error).self) {
        try await app.autoRevert()
      }
      #expect(try await relationExists("vsq_migration_fixture", on: app.db))
      #expect(try await migrationRecordCount(on: app.db) == 1)
    }
  }

  @Test("concurrent migration runners serialize and apply once")
  func concurrentMigrationRunners() async throws {
    try await withPostgresApp(maximumConnections: 2) { firstApp in
      try await resetMigrationFixtures(on: firstApp.db)
      try await withPostgresApp(maximumConnections: 2) { secondApp in
        firstApp.migrations.add(CountedMigration(name: "serialized"))
        secondApp.migrations.add(CountedMigration(name: "serialized"))

        async let first: Void = firstApp.autoMigrate()
        async let second: Void = secondApp.autoMigrate()
        _ = try await (first, second)

        #expect(try await migrationEventCount(on: firstApp.db) == 1)
        #expect(try await migrationRecordCount(on: firstApp.db) == 1)
      }
    }
  }

  @Test("migration batches and legacy history preserve deterministic order")
  func migrationOrderingAndLegacyUpgrade() async throws {
    try await withPostgresApp { app in
      try await resetMigrationFixtures(on: app.db)
      try await app.db.execute(
        #sql(
          """
          CREATE TABLE "_database_migrations" (
            "name" TEXT PRIMARY KEY,
            "batch" BIGINT NOT NULL
          )
          """,
          as: Void.self
        )
      )
      try await app.db.execute(
        #sql(
          """
          INSERT INTO "_database_migrations" ("name", "batch")
          VALUES ('registered-first', 1), ('alphabetical-first', 1)
          """,
          as: Void.self
        )
      )
      app.migrations.add(
        EventMigration(name: "registered-first"),
        EventMigration(name: "alphabetical-first")
      )
      try await app.migrator.setupIfNeeded()
      try await app.migrator.setupIfNeeded()

      let sequences = try await #sql(
        "SELECT \"sequence\" FROM \"_database_migrations\" ORDER BY \"name\"",
        as: Int.self
      )
      .all(on: app.db)
      #expect(sequences == [2, 1])

      app.migrations.add(EventMigration(name: "batch-two-first"))
      try await app.autoMigrate()
      app.migrations.add(EventMigration(name: "batch-three-first"))
      try await app.autoMigrate()
      try await app.autoRevert()
      try await app.revertAllMigrationBatches()

      let events = try await #sql(
        "SELECT \"value\" FROM \"vsq_migration_events\" ORDER BY \"id\"",
        as: String.self
      )
      .all(on: app.db)
      #expect(
        events
          == [
            "prepare:batch-two-first",
            "prepare:batch-three-first",
            "revert:batch-three-first",
            "revert:batch-two-first",
            "revert:alphabetical-first",
            "revert:registered-first",
          ]
      )
    }
  }

  @Test("unknown history and cancellation roll back and permit retry")
  func migrationUnknownCancellationAndRetry() async throws {
    try await withPostgresApp(maximumConnections: 2) { app in
      try await resetMigrationFixtures(on: app.db)
      try await app.db.execute(
        #sql(
          """
          CREATE TABLE "_database_migrations" (
            "name" TEXT PRIMARY KEY,
            "batch" BIGINT NOT NULL
          )
          """,
          as: Void.self
        )
      )
      try await app.db.execute(
        #sql(
          "INSERT INTO \"_database_migrations\" (\"name\", \"batch\") VALUES ('removed', 1)",
          as: Void.self
        )
      )
      app.migrations.add(CreateMigrationFixture(name: "current"))
      await #expect(throws: MigrationError.self) {
        try await app.autoMigrate()
      }
      #expect(try await columnExists("sequence", on: app.db) == false)

      try await resetMigrationFixtures(on: app.db)
      app.migrations.add(SlowMigration(name: "slow"))
      let task = Task {
        try await app.autoMigrate()
      }
      try await Task.sleep(for: .milliseconds(150))
      task.cancel()
      await #expect(throws: (any Error).self) {
        try await task.value
      }
      #expect(try await relationExists("vsq_migration_fixture", on: app.db) == false)
    }

    try await withPostgresApp { retryApp in
      retryApp.migrations.add(CreateMigrationFixture(name: "slow"))
      try await retryApp.autoMigrate()
      #expect(try await relationExists("vsq_migration_fixture", on: retryApp.db))
      try await resetMigrationFixtures(on: retryApp.db)
    }
  }

  @Test("non-transactional Postgres DDL is rejected without bookkeeping")
  func nonTransactionalMigrationDDL() async throws {
    try await withPostgresApp { app in
      try await resetMigrationFixtures(on: app.db)
      app.migrations.add(ConcurrentIndexMigration())

      await #expect(throws: (any Error).self) {
        try await app.autoMigrate()
      }
      #expect(try await relationExists("vsq_migration_fixture", on: app.db) == false)
      #expect(try await relationExists("_database_migrations", on: app.db) == false)
    }
  }
}

private struct Rollback: Error {}
private struct MissingPostgresConfiguration: Error {}

private struct CreateMigrationFixture: AsyncMigration {
  let name: String

  func prepare(on database: any Database) async throws {
    try await database.execute(
      #sql("CREATE TABLE \"vsq_migration_fixture\" (\"id\" BIGINT PRIMARY KEY)", as: Void.self)
    )
  }

  func revert(on database: any Database) async throws {
    try await database.execute(#sql("DROP TABLE \"vsq_migration_fixture\"", as: Void.self))
  }
}

private struct CountedMigration: AsyncMigration {
  let name: String

  func prepare(on database: any Database) async throws {
    try await database.execute(
      #sql(
        """
        CREATE TABLE IF NOT EXISTS "vsq_migration_events" (
          "id" BIGSERIAL PRIMARY KEY,
          "value" TEXT NOT NULL
        )
        """,
        as: Void.self
      )
    )
    try await database.execute(
      #sql(
        "INSERT INTO \"vsq_migration_events\" (\"value\") VALUES ('applied')",
        as: Void.self
      )
    )
  }

  func revert(on database: any Database) async throws {}
}

private struct EventMigration: AsyncMigration {
  let name: String

  func prepare(on database: any Database) async throws {
    try await self.record("prepare:\(self.name)", on: database)
  }

  func revert(on database: any Database) async throws {
    try await self.record("revert:\(self.name)", on: database)
  }

  private func record(_ value: String, on database: any Database) async throws {
    try await database.execute(
      #sql(
        """
        CREATE TABLE IF NOT EXISTS "vsq_migration_events" (
          "id" BIGSERIAL PRIMARY KEY,
          "value" TEXT NOT NULL
        )
        """,
        as: Void.self
      )
    )
    try await database.execute(
      #sql(
        "INSERT INTO \"vsq_migration_events\" (\"value\") VALUES (\(bind: value))",
        as: Void.self
      )
    )
  }
}

private struct SlowMigration: AsyncMigration {
  let name: String

  func prepare(on database: any Database) async throws {
    try await database.execute(#sql("SELECT pg_sleep(0.5)", as: Void.self))
    try await database.execute(
      #sql("CREATE TABLE \"vsq_migration_fixture\" (\"id\" BIGINT PRIMARY KEY)", as: Void.self)
    )
  }

  func revert(on database: any Database) async throws {}
}

private struct ConcurrentIndexMigration: AsyncMigration {
  let name = "concurrent-index"

  func prepare(on database: any Database) async throws {
    try await database.execute(
      #sql("CREATE TABLE \"vsq_migration_fixture\" (\"id\" BIGINT PRIMARY KEY)", as: Void.self)
    )
    try await database.execute(
      #sql(
        """
        CREATE INDEX CONCURRENTLY "vsq_migration_fixture_id"
        ON "vsq_migration_fixture" ("id")
        """,
        as: Void.self
      )
    )
  }

  func revert(on database: any Database) async throws {}
}

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

private func resetMigrationFixtures(on database: any Database) async throws {
  try await database.execute(
    #sql("DROP TABLE IF EXISTS \"_database_migrations\" CASCADE", as: Void.self)
  )
  try await database.execute(
    #sql("DROP TABLE IF EXISTS \"vsq_migration_fixture\" CASCADE", as: Void.self)
  )
  try await database.execute(
    #sql("DROP TABLE IF EXISTS \"vsq_migration_events\" CASCADE", as: Void.self)
  )
  try await database.execute(
    #sql("DROP TABLE IF EXISTS \"vsq_migration_guard\" CASCADE", as: Void.self)
  )
}

private func relationExists(_ name: String, on database: any Database) async throws -> Bool {
  try await #sql("SELECT to_regclass(\(bind: name)) IS NOT NULL", as: Bool.self)
    .first(on: database) ?? false
}

private func columnExists(_ name: String, on database: any Database) async throws -> Bool {
  try await #sql(
    """
    SELECT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_name = '_database_migrations'
        AND column_name = \(bind: name)
    )
    """,
    as: Bool.self
  )
  .first(on: database) ?? false
}

private func migrationRecordCount(on database: any Database) async throws -> Int {
  try await #sql("SELECT COUNT(*) FROM \"_database_migrations\"", as: Int.self)
    .first(on: database) ?? 0
}

private func migrationEventCount(on database: any Database) async throws -> Int {
  try await #sql("SELECT COUNT(*) FROM \"vsq_migration_events\"", as: Int.self)
    .first(on: database) ?? 0
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
