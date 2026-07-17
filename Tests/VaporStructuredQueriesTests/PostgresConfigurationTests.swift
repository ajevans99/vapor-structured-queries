import Testing
import VaporStructuredQueries
import VaporStructuredQueriesPostgresNIO

struct PostgresConfigurationTests {
  @Test("production configuration validates owned connection fields")
  func connectionValidation() {
    #expect(throws: DatabaseRuntimeError.invalidConfiguration(field: "hostname")) {
      _ = try DatabaseConfigurationFactory.postgres(
        hostname: "",
        username: "vapor",
        password: nil,
        database: "vapor"
      )
    }
    #expect(throws: DatabaseRuntimeError.invalidConfiguration(field: "port")) {
      _ = try DatabaseConfigurationFactory.postgres(
        hostname: "localhost",
        port: 0,
        username: "vapor",
        password: nil,
        database: "vapor"
      )
    }
    #expect(throws: DatabaseRuntimeError.invalidConfiguration(field: "username")) {
      _ = try DatabaseConfigurationFactory.postgres(
        hostname: "localhost",
        username: "",
        password: nil,
        database: "vapor"
      )
    }
  }

  @Test("configuration validates pool bounds")
  func poolValidation() {
    var options = PostgresClient.Configuration.Options()
    options.minimumConnections = 2
    options.maximumConnections = 2

    #expect(throws: Never.self) {
      _ = try DatabaseConfigurationFactory.postgresInsecureForLocalDevelopment(
        username: "vapor",
        password: nil,
        database: "vapor",
        options: options
      )
    }

    options.minimumConnections = 0
    options.maximumConnections = 0
    #expect(
      throws: DatabaseRuntimeError.invalidConfiguration(field: "maximumConnections")
    ) {
      _ = try DatabaseConfigurationFactory.postgresInsecureForLocalDevelopment(
        username: "vapor",
        password: nil,
        database: "vapor",
        options: options
      )
    }
  }
}
