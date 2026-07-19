import StructuredQueries
import Testing
import Vapor
import VaporStructuredQueries
import VaporStructuredQueriesTestSupport
import VaporTesting

private actor MigrationEvents {
  var values: [String] = []

  func append(_ value: String) {
    self.values.append(value)
  }
}

private struct RecordingMigration: AsyncMigration {
  let name: String
  let events: MigrationEvents
  var failure: TestMigrationFailure?

  func prepare(on database: any Database) async throws {
    await self.events.append("prepare:\(self.name)")
    if let failure {
      throw failure
    }
  }

  func revert(on database: any Database) async throws {
    await self.events.append("revert:\(self.name)")
    if let failure {
      throw failure
    }
  }
}

private struct TestMigrationFailure: Error, Equatable {}

@Suite(.serialized)
struct MigratorTests {
  @Test("prepare applies in registration order and records sequence")
  func prepareOrder() async throws {
    let database = FakeDatabase(supportsMigrationLock: true)
    let events = MigrationEvents()

    try await withMigrationApp(database: database) { app in
      app.migrations.add(
        RecordingMigration(name: "z-last-alphabetically", events: events),
        RecordingMigration(name: "a-first-alphabetically", events: events)
      )
      try await app.autoMigrate()
    }

    #expect(
      await events.values
        == [
          "prepare:z-last-alphabetically",
          "prepare:a-first-alphabetically",
        ]
    )
    let inserts = database.recordedStatements().filter {
      $0.sql.contains("INSERT INTO \"_database_migrations\"")
    }
    #expect(inserts.count == 2)
    #expect(database.migrationOperationCounts().committed == 1)
  }

  @Test("latest revert uses persisted reverse application order")
  func latestRevertOrder() async throws {
    let database = FakeDatabase(supportsMigrationLock: true)
    let events = MigrationEvents()
    database.queueAll(
      [
        AppliedMigrationRecord(name: "first", batch: 1, sequence: 1),
        AppliedMigrationRecord(name: "second", batch: 2, sequence: 2),
        AppliedMigrationRecord(name: "third", batch: 2, sequence: 3),
      ],
      forSQL: historySQL
    )

    try await withMigrationApp(database: database) { app in
      app.migrations.add(
        RecordingMigration(name: "first", events: events),
        RecordingMigration(name: "second", events: events),
        RecordingMigration(name: "third", events: events)
      )
      try await app.autoRevert()
    }

    #expect(await events.values == ["revert:third", "revert:second"])
  }

  @Test("explicit all-batches revert uses persisted reverse application order")
  func allBatchesRevertOrder() async throws {
    let database = FakeDatabase(supportsMigrationLock: true)
    let events = MigrationEvents()
    database.queueAll(
      [
        AppliedMigrationRecord(name: "first", batch: 1, sequence: 1),
        AppliedMigrationRecord(name: "second", batch: 2, sequence: 2),
        AppliedMigrationRecord(name: "third", batch: 2, sequence: 3),
      ],
      forSQL: historySQL
    )

    try await withMigrationApp(database: database) { app in
      app.migrations.add(
        RecordingMigration(name: "first", events: events),
        RecordingMigration(name: "second", events: events),
        RecordingMigration(name: "third", events: events)
      )
      try await app.revertAllMigrationBatches()
    }

    #expect(await events.values == ["revert:third", "revert:second", "revert:first"])
  }

  @Test("migrate command routes latest and all-batch reverts explicitly")
  func migrateCommandRevertRouting() async throws {
    let latestDatabase = FakeDatabase(supportsMigrationLock: true)
    let latestEvents = MigrationEvents()
    latestDatabase.queueAll(
      [
        AppliedMigrationRecord(name: "first", batch: 1, sequence: 1),
        AppliedMigrationRecord(name: "second", batch: 2, sequence: 2),
      ],
      forSQL: historySQL
    )

    try await withMigrationApp(database: latestDatabase) { app in
      app.migrations.add(
        RecordingMigration(name: "first", events: latestEvents),
        RecordingMigration(name: "second", events: latestEvents)
      )
      try await runMigrateCommand(["vapor", "--revert"], on: app)
    }
    #expect(await latestEvents.values == ["revert:second"])

    let allDatabase = FakeDatabase(supportsMigrationLock: true)
    let allEvents = MigrationEvents()
    allDatabase.queueAll(
      [
        AppliedMigrationRecord(name: "first", batch: 1, sequence: 1),
        AppliedMigrationRecord(name: "second", batch: 2, sequence: 2),
      ],
      forSQL: historySQL
    )

    try await withMigrationApp(database: allDatabase) { app in
      app.migrations.add(
        RecordingMigration(name: "first", events: allEvents),
        RecordingMigration(name: "second", events: allEvents)
      )
      try await runMigrateCommand(["vapor", "--revert-all"], on: app)
    }
    #expect(await allEvents.values == ["revert:second", "revert:first"])
  }

  @Test("migrate command rejects conflicting revert flags")
  func migrateCommandRejectsConflictingFlags() async throws {
    try await withApp { app in
      await #expect(throws: MigrationError.conflictingCommandOptions) {
        try await runMigrateCommand(["vapor", "--revert", "--revert-all"], on: app)
      }
    }
  }

  @Test("unknown applied migration stops before migration mutation")
  func unknownMigration() async throws {
    let database = FakeDatabase(supportsMigrationLock: true)
    let events = MigrationEvents()
    let unknown = AppliedMigrationRecord(name: "removed", batch: 4, sequence: 9)
    database.queueAll([unknown], forSQL: historySQL)

    await #expect(
      throws: MigrationError.unknownAppliedMigrations(
        database: MigrationDatabaseSnapshot(id: "test"),
        migrations: [unknown]
      )
    ) {
      try await withMigrationApp(database: database) { app in
        app.migrations.add(RecordingMigration(name: "current", events: events))
        try await app.autoMigrate()
      }
    }

    #expect(await events.values.isEmpty)
    #expect(
      !database.recordedStatements().contains {
        $0.sql.contains("DELETE FROM \"_database_migrations\"")
      }
    )
    #expect(database.migrationOperationCounts().rolledBack == 1)
  }

  @Test("legacy records backfill by registration order")
  func legacyBackfill() async throws {
    let database = FakeDatabase(supportsMigrationLock: true)
    let events = MigrationEvents()
    database.queueAll(
      [
        AppliedMigrationRecord(name: "alphabetical-first", batch: 1, sequence: nil),
        AppliedMigrationRecord(name: "registered-first", batch: 1, sequence: nil),
      ],
      forSQL: historySQL
    )

    try await withMigrationApp(database: database) { app in
      app.migrations.add(
        RecordingMigration(name: "registered-first", events: events),
        RecordingMigration(name: "alphabetical-first", events: events)
      )
      try await app.migrator.setupIfNeeded()
    }

    let updates = database.recordedStatements().filter {
      $0.sql.contains("UPDATE \"_database_migrations\"")
    }
    #expect(updates.count == 2)
    #expect(database.migrationOperationCounts().committed == 1)
  }

  @Test("migration failure rolls back the modeled operation")
  func migrationFailure() async throws {
    let database = FakeDatabase(supportsMigrationLock: true)
    let events = MigrationEvents()

    await #expect(throws: TestMigrationFailure.self) {
      try await withMigrationApp(database: database) { app in
        app.migrations.add(
          RecordingMigration(name: "fails", events: events, failure: TestMigrationFailure())
        )
        try await app.autoMigrate()
      }
    }

    #expect(database.migrationOperationCounts() == (committed: 0, rolledBack: 1))
    #expect(
      !database.recordedStatements().contains {
        $0.sql.contains("INSERT INTO \"_database_migrations\"")
      }
    )
  }

  @Test("duplicate names fail before database mutation")
  func duplicateNames() async throws {
    let database = FakeDatabase(supportsMigrationLock: true)
    let events = MigrationEvents()

    await #expect(
      throws: MigrationError.duplicateRegisteredNames(
        database: MigrationDatabaseSnapshot(id: "test"),
        names: ["duplicate"]
      )
    ) {
      try await withMigrationApp(database: database) { app in
        app.migrations.add(
          RecordingMigration(name: "duplicate", events: events),
          RecordingMigration(name: "duplicate", events: events)
        )
        try await app.autoMigrate()
      }
    }

    #expect(database.recordedStatements().isEmpty)
  }

  @Test("non-capable driver fails closed")
  func unsupportedDriver() async throws {
    let database = FakeDatabase()
    let events = MigrationEvents()

    await #expect(throws: DatabaseRuntimeError.unsupportedOperation(.migrationLock)) {
      try await withMigrationApp(database: database) { app in
        app.migrations.add(RecordingMigration(name: "migration", events: events))
        try await app.autoMigrate()
      }
    }
    #expect(database.recordedStatements().isEmpty)
  }

  @Test("databases without registered migrations are not mutated")
  func unrelatedDatabase() async throws {
    let database = FakeDatabase(supportsMigrationLock: true)
    let unrelated = FakeDatabase()
    let events = MigrationEvents()

    try await withApp { app in
      try await app.database.use(.init { _, _ in database }, as: "test")
      try await app.database.use(.init { _, _ in unrelated }, as: "unrelated")
      app.database.default(to: "test")
      app.migrations.add(RecordingMigration(name: "migration", events: events))
      try await app.autoMigrate()
    }

    #expect(unrelated.recordedStatements().isEmpty)
  }
}

private let historySQL = """
  SELECT "name", "batch", "sequence"
  FROM "_database_migrations"
  ORDER BY "batch" ASC, "name" ASC
  """

private func withMigrationApp<Result: Sendable>(
  database: FakeDatabase,
  _ operation: (Application) async throws -> sending Result
) async throws -> sending Result {
  try await withApp { app in
    try await app.database.use(.init { _, _ in database }, as: "test")
    app.database.default(to: "test")
    return try await operation(app)
  }
}

private func runMigrateCommand(_ arguments: [String], on app: Application) async throws {
  var input = CommandInput(arguments: arguments)
  let signature = try MigrateCommand.Signature(from: &input)
  var context = CommandContext(console: app.console, input: input)
  context.application = app
  try await MigrateCommand().run(using: context, signature: signature)
}
