import Foundation
import StructuredQueries
import Testing
import VaporStructuredQueries
import VaporStructuredQueriesPostgresNIO
import VaporTesting

struct PostgresIntegrationTests {
  @Test(
    "postgres query flow",
    .enabled(
      if: Environment.liveTestsEnabled,
      "Set RUN_POSTGRES_INTEGRATION_TESTS=1 and POSTGRES_HOST, POSTGRES_USER, POSTGRES_DB"
    )
  )
  func postgresQueryFlow() async throws {
    let configuration = try Environment.configuration()

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
        "CREATE TABLE \(quote: tableName) (\"id\" BIGINT PRIMARY KEY, \"title\" TEXT NOT NULL)",
        as: Void.self
      )
      .execute(on: app.db)

      try await withTestTableCleanup(named: tableName, on: app.db) {
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

      try await verifyTypedQueryFlow(on: app.db)
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

  static func configuration() throws -> Configuration {
    let values = ProcessInfo.processInfo.environment
    let host = try #require(values["POSTGRES_HOST"], "POSTGRES_HOST is required for live tests")
    let username = try #require(values["POSTGRES_USER"], "POSTGRES_USER is required for live tests")
    let database = try #require(values["POSTGRES_DB"], "POSTGRES_DB is required for live tests")
    let port: Int
    if let value = values["POSTGRES_PORT"] {
      port = try #require(Int(value), "POSTGRES_PORT must be an integer")
      try #require((1...65535).contains(port), "POSTGRES_PORT must be in 1...65535")
    } else {
      port = 5432
    }
    let password = values["POSTGRES_PASSWORD"]

    return .init(
      host: host,
      port: port,
      username: username,
      password: password,
      database: database
    )
  }
}
