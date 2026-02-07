import Foundation
import StructuredQueries
import Testing
import VaporStructuredQueries
import VaporStructuredQueriesPostgresNIO
import VaporTesting

struct PostgresIntegrationTests {
  @Test("postgres query flow")
  func postgresQueryFlow() async throws {
    guard Environment.liveTestsEnabled, let configuration = Environment.configuration else {
      return
    }

    try await withApp { app in
      app.database.use(
        .postgres(
          hostname: configuration.host,
          port: configuration.port,
          username: configuration.username,
          password: configuration.password,
          database: configuration.database
        ),
        as: .psql
      )
      app.database.default(to: .psql)

      let tableName = "vsq_temp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
      let titleToInsert = "Blob"

      try await #sql(
        "CREATE TEMP TABLE \(quote: tableName) (\"id\" BIGINT PRIMARY KEY, \"title\" TEXT NOT NULL)",
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
      #expect(title == "Blob")

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
}

private enum Environment {
  struct Configuration: Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String?
    let database: String
  }

  static var liveTestsEnabled: Bool {
    ProcessInfo.processInfo.environment["RUN_POSTGRES_INTEGRATION_TESTS"] == "1"
  }

  static var configuration: Configuration? {
    let values = ProcessInfo.processInfo.environment

    guard
      let host = values["POSTGRES_HOST"],
      let username = values["POSTGRES_USER"],
      let database = values["POSTGRES_DB"]
    else {
      return nil
    }

    let password = values["POSTGRES_PASSWORD"]
    let port = Int(values["POSTGRES_PORT"] ?? "") ?? 5432

    return .init(
      host: host,
      port: port,
      username: username,
      password: password,
      database: database
    )
  }
}
