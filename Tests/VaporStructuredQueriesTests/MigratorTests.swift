import StructuredQueries
import Testing
import VaporStructuredQueries
import VaporStructuredQueriesTestSupport
import VaporTesting

private struct CreateWidgetsMigration: AsyncMigration {
  let name = "CreateWidgetsMigration"

  func prepare(on database: any Database) async throws {
    try await #sql(
      "CREATE TABLE \"widgets\" (\"id\" BIGINT PRIMARY KEY)",
      as: Void.self
    )
    .execute(on: database)
  }

  func revert(on database: any Database) async throws {
    try await #sql(
      "DROP TABLE \"widgets\"",
      as: Void.self
    )
    .execute(on: database)
  }
}

struct MigratorTests {
  @Test("autoMigrate creates tracking table and records migrations")
  func autoMigrate() async throws {
    let database = FakeDatabase()

    try await withApp { app in
      app.database.use(
        .init { _, _ in database },
        as: "test"
      )
      app.database.default(to: "test")
      app.structuredQueriesMigrations.add(CreateWidgetsMigration())

      try await app.structuredQueriesAutoMigrate()
    }

    let statements = database.recordedStatements().map(\.sql)
    #expect(
      statements.contains(
        "CREATE TABLE IF NOT EXISTS \"_database_migrations\" (\n  \"name\" TEXT PRIMARY KEY,\n  \"batch\" BIGINT NOT NULL\n)"
      )
    )
    #expect(statements.contains("SELECT \"name\" FROM \"_database_migrations\""))
    #expect(
      statements.contains("SELECT COALESCE(MAX(\"batch\"), 0) + 1 FROM \"_database_migrations\"")
    )
    #expect(statements.contains("CREATE TABLE \"widgets\" (\"id\" BIGINT PRIMARY KEY)"))
    #expect(
      statements.contains(
        "INSERT INTO \"_database_migrations\" (\"name\", \"batch\") VALUES (?, ?)"
      )
    )
  }

  @Test("autoRevert reverts tracked migration")
  func autoRevert() async throws {
    let database = FakeDatabase()
    database.queueAll(
      ["CreateWidgetsMigration"],
      forSQL: "SELECT \"name\" FROM \"_database_migrations\" ORDER BY \"batch\" DESC, \"name\" DESC"
    )

    try await withApp { app in
      app.database.use(
        .init { _, _ in database },
        as: "test"
      )
      app.database.default(to: "test")
      app.structuredQueriesMigrations.add(CreateWidgetsMigration())

      try await app.structuredQueriesAutoRevert()
    }

    let statements = database.recordedStatements().map(\.sql)
    #expect(statements.contains("DROP TABLE \"widgets\""))
    #expect(statements.contains("DELETE FROM \"_database_migrations\" WHERE \"name\" = ?"))
  }

  @Test("migrations execute on targeted databases")
  func perDatabaseMigrations() async throws {
    let defaultDatabase = FakeDatabase()
    let analyticsDatabase = FakeDatabase()

    try await withApp { app in
      app.database.use(.init { _, _ in defaultDatabase }, as: "default")
      app.database.use(.init { _, _ in analyticsDatabase }, as: "analytics")
      app.database.default(to: "default")
      app.structuredQueriesMigrations.add(CreateWidgetsMigration(), to: "default")
      app.structuredQueriesMigrations.add(CreateWidgetsMigration(), to: "analytics")

      try await app.structuredQueriesAutoMigrate()
    }

    let defaultSQL = defaultDatabase.recordedStatements().map(\.sql)
    let analyticsSQL = analyticsDatabase.recordedStatements().map(\.sql)

    #expect(defaultSQL.contains("CREATE TABLE \"widgets\" (\"id\" BIGINT PRIMARY KEY)"))
    #expect(analyticsSQL.contains("CREATE TABLE \"widgets\" (\"id\" BIGINT PRIMARY KEY)"))
  }
}
