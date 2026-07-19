import Foundation
import StructuredQueries
import Testing
import VaporStructuredQueries
import VaporStructuredQueriesSQLite
import VaporTesting

@Suite(.serialized)
struct SQLiteIntegrationTests {
  @Test("sqlite query flow")
  func sqliteQueryFlow() async throws {
    try await withApp { app in
      try await app.database.use(.sqlite(path: ":memory:"), as: .sqlite)
      app.database.default(to: .sqlite)

      let tableName = "vsq_temp_sqlite"
      let titleToInsert = "Blob"

      try await #sql(
        "CREATE TABLE \(quote: tableName) (\"id\" INTEGER PRIMARY KEY, \"title\" TEXT NOT NULL)",
        as: Void.self
      )
      .execute(on: app.db)

      try await #sql(
        "INSERT INTO \(quote: tableName) (\"id\", \"title\") VALUES (\(bind: 1), \(bind: titleToInsert))",
        as: Void.self
      )
      .execute(on: app.db)

      let title = try await #sql(
        "SELECT \"title\" FROM \(quote: tableName) WHERE \"id\" = \(bind: 1)",
        as: String.self
      )
      .first(on: app.db)
      #expect(title == titleToInsert)

      try await #sql(
        "DELETE FROM \(quote: tableName) WHERE \"id\" = \(bind: 1)",
        as: Void.self
      )
      .execute(on: app.db)

      let count = try await #sql(
        "SELECT COUNT(*) FROM \(quote: tableName)",
        as: Int.self
      )
      .first(on: app.db)
      #expect(count == 0)
    }
  }

  @Test("sqlite readiness and unsupported atomic APIs")
  func sqliteRuntimeCapabilities() async throws {
    try await withApp { app in
      try await app.database.use(.sqlite(path: ":memory:"), as: .sqlite)
      app.database.default(to: .sqlite)

      try await app.db.checkReadiness()
      await #expect(throws: DatabaseRuntimeError.unsupportedOperation(.connection)) {
        try await app.db.withConnection { _ in () }
      }
      await #expect(throws: DatabaseRuntimeError.unsupportedOperation(.transaction)) {
        try await app.db.withTransaction { _ in () }
      }
      try await app.db.withMigrationLock { database in
        #expect(database.migrationDialect == .sqlite)
      }
    }
  }

  @Test("file-backed concurrent migration runners serialize and apply once")
  func concurrentMigrationRunners() async throws {
    try await withTemporarySQLitePath { path in
      try await withSQLiteApp(path: path) { firstApp in
        try await withSQLiteApp(path: path) { secondApp in
          firstApp.migrations.add(
            SQLiteCountedMigration(name: "serialized", delay: .milliseconds(200))
          )
          secondApp.migrations.add(SQLiteCountedMigration(name: "serialized"))

          async let first: Void = firstApp.autoMigrate()
          try await Task.sleep(for: .milliseconds(30))
          async let second: Void = secondApp.autoMigrate()
          _ = try await (first, second)

          #expect(try await sqliteEventCount(on: firstApp.db) == 1)
          #expect(try await sqliteMigrationCount(on: firstApp.db) == 1)
        }
      }
    }
  }

  @Test("file-backed prepare and bookkeeping failures roll back")
  func prepareAndBookkeepingRollback() async throws {
    try await withTemporarySQLitePath { path in
      try await withSQLiteApp(path: path) { app in
        app.migrations.add(SQLiteFailingMigration(name: "body-failure"))
        await #expect(throws: SQLiteTestFailure.self) {
          try await app.autoMigrate()
        }
        let fixtureExists = try await sqliteRelationExists("vsq_sqlite_fixture", on: app.db)
        #expect(fixtureExists == false)
      }

      try await withSQLiteApp(path: path) { app in
        try await app.db.execute(
          #sql("DROP TABLE IF EXISTS \"_database_migrations\"", as: Void.self)
        )
        try await app.db.execute(
          #sql(
            """
            CREATE TABLE "_database_migrations" (
              "name" TEXT PRIMARY KEY CHECK ("name" <> 'bookkeeping-failure'),
              "batch" INTEGER NOT NULL,
              "sequence" INTEGER NOT NULL UNIQUE
            )
            """,
            as: Void.self
          )
        )
        app.migrations.add(SQLiteFixtureMigration(name: "bookkeeping-failure"))
        await #expect(throws: (any Error).self) {
          try await app.autoMigrate()
        }
        #expect(try await sqliteRelationExists("vsq_sqlite_fixture", on: app.db) == false)
        #expect(try await sqliteMigrationCount(on: app.db) == 0)
      }
    }
  }

  @Test("file-backed revert bookkeeping failure rolls back")
  func revertRollback() async throws {
    try await withTemporarySQLitePath { path in
      try await withSQLiteApp(path: path) { app in
        app.migrations.add(SQLiteFixtureMigration(name: "revert-failure"))
        try await app.autoMigrate()
        try await app.db.execute(
          #sql(
            """
            CREATE TRIGGER "vsq_reject_migration_delete"
            BEFORE DELETE ON "_database_migrations"
            BEGIN
              SELECT RAISE(ABORT, 'bookkeeping rejected');
            END
            """,
            as: Void.self
          )
        )

        await #expect(throws: (any Error).self) {
          try await app.autoRevert()
        }
        #expect(try await sqliteRelationExists("vsq_sqlite_fixture", on: app.db))
        #expect(try await sqliteMigrationCount(on: app.db) == 1)
      }
    }
  }

  @Test("file-backed order, latest/all batches, and legacy rebuild are deterministic")
  func orderingAndLegacyUpgrade() async throws {
    try await withTemporarySQLitePath { path in
      try await withSQLiteApp(path: path) { app in
        try await app.db.execute(
          #sql(
            """
            CREATE TABLE "_database_migrations" (
              "name" TEXT PRIMARY KEY,
              "batch" INTEGER NOT NULL
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
          SQLiteEventMigration(name: "registered-first"),
          SQLiteEventMigration(name: "alphabetical-first")
        )
        try await app.migrator.setupIfNeeded()
        try await app.migrator.setupIfNeeded()

        let sequences = try await #sql(
          "SELECT \"sequence\" FROM \"_database_migrations\" ORDER BY \"name\"",
          as: Int.self
        )
        .all(on: app.db)
        #expect(sequences == [2, 1])

        app.migrations.add(SQLiteEventMigration(name: "batch-two-first"))
        try await app.autoMigrate()
        app.migrations.add(SQLiteEventMigration(name: "batch-three-first"))
        try await app.autoMigrate()
        try await app.autoRevert()
        try await app.revertAllMigrationBatches()

        let events = try await #sql(
          "SELECT \"value\" FROM \"vsq_sqlite_events\" ORDER BY \"id\"",
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
  }

  @Test("unknown legacy names roll back schema evolution")
  func unknownLegacyMigration() async throws {
    try await withTemporarySQLitePath { path in
      try await withSQLiteApp(path: path) { app in
        try await app.db.execute(
          #sql(
            """
            CREATE TABLE "_database_migrations" (
              "name" TEXT PRIMARY KEY,
              "batch" INTEGER NOT NULL
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
        app.migrations.add(SQLiteFixtureMigration(name: "current"))

        await #expect(throws: MigrationError.self) {
          try await app.autoMigrate()
        }
        #expect(try await sqliteSequenceColumnExists(on: app.db) == false)
        #expect(try await sqliteRelationExists("vsq_sqlite_fixture", on: app.db) == false)
      }
    }
  }

  @Test("file-lock waiter cancellation releases cleanly and retry succeeds")
  func cancellationAndRetry() async throws {
    try await withTemporarySQLitePath { path in
      try await withSQLiteApp(path: path) { firstApp in
        try await withSQLiteApp(path: path) { secondApp in
          firstApp.migrations.add(SQLiteCountedMigration(name: "slow", delay: .milliseconds(400)))
          secondApp.migrations.add(SQLiteCountedMigration(name: "slow"))

          let holder = Task { try await firstApp.autoMigrate() }
          try await Task.sleep(for: .milliseconds(40))
          let waiter = Task { try await secondApp.autoMigrate() }
          try await Task.sleep(for: .milliseconds(80))
          waiter.cancel()
          await #expect(throws: CancellationError.self) {
            try await waiter.value
          }
          try await holder.value
          try await secondApp.autoMigrate()
          #expect(try await sqliteEventCount(on: secondApp.db) == 1)
        }
      }
    }
  }
}

private struct SQLiteTestFailure: Error, Equatable {}

private struct SQLiteFixtureMigration: AsyncMigration {
  let name: String

  func prepare(on database: any Database) async throws {
    try await database.execute(
      #sql("CREATE TABLE \"vsq_sqlite_fixture\" (\"id\" INTEGER PRIMARY KEY)", as: Void.self)
    )
  }

  func revert(on database: any Database) async throws {
    try await database.execute(#sql("DROP TABLE \"vsq_sqlite_fixture\"", as: Void.self))
  }
}

private struct SQLiteFailingMigration: AsyncMigration {
  let name: String

  func prepare(on database: any Database) async throws {
    try await database.execute(
      #sql("CREATE TABLE \"vsq_sqlite_fixture\" (\"id\" INTEGER PRIMARY KEY)", as: Void.self)
    )
    throw SQLiteTestFailure()
  }

  func revert(on database: any Database) async throws {}
}

private struct SQLiteCountedMigration: AsyncMigration {
  let name: String
  var delay: Duration = .zero

  func prepare(on database: any Database) async throws {
    if self.delay > .zero {
      try await Task.sleep(for: self.delay)
    }
    try await database.execute(
      #sql(
        """
        CREATE TABLE IF NOT EXISTS "vsq_sqlite_events" (
          "id" INTEGER PRIMARY KEY AUTOINCREMENT,
          "value" TEXT NOT NULL
        )
        """,
        as: Void.self
      )
    )
    try await database.execute(
      #sql("INSERT INTO \"vsq_sqlite_events\" (\"value\") VALUES ('applied')", as: Void.self)
    )
  }

  func revert(on database: any Database) async throws {}
}

private struct SQLiteEventMigration: AsyncMigration {
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
        CREATE TABLE IF NOT EXISTS "vsq_sqlite_events" (
          "id" INTEGER PRIMARY KEY AUTOINCREMENT,
          "value" TEXT NOT NULL
        )
        """,
        as: Void.self
      )
    )
    try await database.execute(
      #sql(
        "INSERT INTO \"vsq_sqlite_events\" (\"value\") VALUES (\(bind: value))",
        as: Void.self
      )
    )
  }
}

private func withSQLiteApp<Result: Sendable>(
  path: String,
  _ operation: (Application) async throws -> sending Result
) async throws -> sending Result {
  try await withApp { app in
    try await app.database.use(.sqlite(path: path), as: .sqlite)
    app.database.default(to: .sqlite)
    return try await operation(app)
  }
}

private func withTemporarySQLitePath<Result: Sendable>(
  _ operation: (String) async throws -> sending Result
) async throws -> sending Result {
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("vapor-structured-queries-\(UUID().uuidString).sqlite")
    .path
  defer {
    try? FileManager.default.removeItem(atPath: path)
  }
  return try await operation(path)
}

private func sqliteRelationExists(
  _ name: String,
  on database: any Database
) async throws -> Bool {
  try await #sql(
    """
    SELECT EXISTS (
      SELECT 1 FROM "sqlite_master"
      WHERE "type" = 'table' AND "name" = \(bind: name)
    )
    """,
    as: Bool.self
  )
  .first(on: database) ?? false
}

private func sqliteSequenceColumnExists(on database: any Database) async throws -> Bool {
  (try await #sql(
    """
    SELECT COUNT(*) FROM pragma_table_info('_database_migrations')
    WHERE "name" = 'sequence'
    """,
    as: Int.self
  )
  .first(on: database) ?? 0) == 1
}

private func sqliteMigrationCount(on database: any Database) async throws -> Int {
  try await #sql("SELECT COUNT(*) FROM \"_database_migrations\"", as: Int.self)
    .first(on: database) ?? 0
}

private func sqliteEventCount(on database: any Database) async throws -> Int {
  try await #sql("SELECT COUNT(*) FROM \"vsq_sqlite_events\"", as: Int.self)
    .first(on: database) ?? 0
}
