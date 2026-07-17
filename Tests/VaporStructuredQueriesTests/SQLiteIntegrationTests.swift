import StructuredQueries
import Testing
import VaporStructuredQueries
import VaporStructuredQueriesSQLite
import VaporTesting

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
    }
  }
}
