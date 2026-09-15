import Foundation
import Logging
import StructuredQueries
import StructuredQueriesPostgresNIO
import Testing
import VaporStructuredQueries
import VaporStructuredQueriesPostgresNIO
import VaporTesting

@Suite(
  .serialized,
  .enabled(
    if: Environment.liveTestsEnabled,
    "Set RUN_POSTGRES_INTEGRATION_TESTS=1 and POSTGRES_HOST, POSTGRES_USER, POSTGRES_DB"
  )
)
struct PostgresIntegrationTests {
  @Test("postgres query flow")
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
      .execute(on: app.structuredQueriesDB)

      try await withTestTableCleanup(named: tableName, on: app.structuredQueriesDB) {
        try await #sql(
          "INSERT INTO \(quote: tableName) (\"id\", \"title\") VALUES (\(bind: 1), \(bind: titleToInsert))",
          as: Void.self
        )
        .execute(on: app.structuredQueriesDB)

        let title = try await #sql(
          "SELECT \"title\" FROM \(quote: tableName) WHERE \"id\" = \(bind: 1)",
          as: String.self
        )
        .first(on: app.structuredQueriesDB)
        #expect(title == "Blob")

        try await #sql(
          "DELETE FROM \(quote: tableName) WHERE \"id\" = \(bind: 1)",
          as: Void.self
        )
        .execute(on: app.structuredQueriesDB)

        let count = try await #sql(
          "SELECT COUNT(*) FROM \(quote: tableName)",
          as: Int.self
        )
        .first(on: app.structuredQueriesDB)
        #expect(count == 0)
      }

      try await verifyTypedQueryFlow(on: app.structuredQueriesDB)
    }
  }

  @Test("borrowed connection preserves transactions and remains owned by its caller")
  func borrowedConnection() async throws {
    let configuration = try Environment.configuration()
    let logger = Logger(label: "borrowed-connection-tests")
    let client = PostgresClient(
      configuration: .init(
        host: configuration.host,
        port: configuration.port,
        username: configuration.username,
        password: configuration.password,
        database: configuration.database,
        tls: .disable
      ),
      backgroundLogger: logger
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await client.run() }
      defer { group.cancelAll() }

      try await client.withConnection { connection in
        let database = connection.structuredQueries(logger: logger)
        try await verifyTypedQueryFlow(on: database)

        let tableName = "vsq_borrowed_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        _ = try await connection.execute(
          #sql("CREATE TABLE \(quote: tableName) (\"id\" BIGINT PRIMARY KEY)", as: Void.self),
          logger: logger
        )

        try await withTestTableCleanup(named: tableName, on: database) {
          _ = try await connection.execute(#sql("BEGIN", as: Void.self), logger: logger)
          do {
            _ = try await connection.execute(
              #sql("INSERT INTO \(quote: tableName) VALUES (\(bind: 1))", as: Void.self),
              logger: logger
            )

            let rows = try await #sql("SELECT \"id\" FROM \(quote: tableName)", as: Int.self)
              .all(on: database)
            #expect(rows == [1])
            #expect(
              try await #sql("SELECT \"id\" FROM \(quote: tableName)", as: Int.self)
                .first(on: database) == 1
            )

            try await #sql("INSERT INTO \(quote: tableName) VALUES (\(bind: 2))", as: Void.self)
              .execute(on: database)

            _ = try await connection.execute(#sql("ROLLBACK", as: Void.self), logger: logger)
          } catch {
            do {
              _ = try await connection.execute(#sql("ROLLBACK", as: Void.self), logger: logger)
            } catch {
              Issue.record(error, "Could not roll back borrowed-connection test transaction")
            }
            throw error
          }

          let rows = try await #sql("SELECT \"id\" FROM \(quote: tableName)", as: Int.self)
            .all(on: database)
          #expect(rows.isEmpty)
          #expect(
            try await #sql("SELECT \"id\" FROM \(quote: tableName)", as: Int.self)
              .first(on: database) == nil
          )

          database.shutdown()
          var ownerRows: [Int] = []
          for try await value in try await connection.query(
            #sql("SELECT \(bind: 42)", as: Int.self),
            logger: logger
          ) {
            ownerRows.append(value)
          }
          #expect(ownerRows == [42])
        }
      }
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
