import StructuredQueriesPostgresNIO
import VaporStructuredQueries

extension DatabaseConfigurationFactory {
  /// Creates a Postgres-backed database configuration factory.
  public static func postgres(
    configuration: PostgresClient.Configuration
  ) throws -> Self {
    try validate(options: configuration.options)
    return .init { eventLoopGroup, logger in
      PostgresDatabase(
        configuration: configuration,
        eventLoopGroup: eventLoopGroup,
        logger: logger
      )
    }
  }

  /// Creates a Postgres configuration that requires verified TLS.
  public static func postgres(
    hostname: String,
    port: Int = 5432,
    username: String,
    password: String?,
    database: String?,
    options: PostgresClient.Configuration.Options = .init()
  ) throws -> Self {
    try validate(hostname: hostname, port: port, username: username, options: options)
    var configuration = PostgresClient.Configuration(
      host: hostname,
      port: port,
      username: username,
      password: password,
      database: database,
      tls: .require(.makeClientConfiguration())
    )
    configuration.options = options
    return try .postgres(configuration: configuration)
  }

  /// Creates an insecure Postgres configuration for local development only.
  public static func postgresInsecureForLocalDevelopment(
    hostname: String = "localhost",
    port: Int = 5432,
    username: String,
    password: String?,
    database: String?,
    options: PostgresClient.Configuration.Options = .init()
  ) throws -> Self {
    try validate(hostname: hostname, port: port, username: username, options: options)
    var configuration = PostgresClient.Configuration(
      host: hostname,
      port: port,
      username: username,
      password: password,
      database: database,
      tls: .disable
    )
    configuration.options = options
    return try .postgres(configuration: configuration)
  }
}

private func validate(
  hostname: String,
  port: Int,
  username: String,
  options: PostgresClient.Configuration.Options
) throws {
  guard !hostname.isEmpty else {
    throw DatabaseRuntimeError.invalidConfiguration(field: "hostname")
  }
  guard (1...65_535).contains(port) else {
    throw DatabaseRuntimeError.invalidConfiguration(field: "port")
  }
  guard !username.isEmpty else {
    throw DatabaseRuntimeError.invalidConfiguration(field: "username")
  }
  try validate(options: options)
}

private func validate(
  options: PostgresClient.Configuration.Options
) throws {
  guard options.minimumConnections >= 0 else {
    throw DatabaseRuntimeError.invalidConfiguration(field: "minimumConnections")
  }
  guard options.maximumConnections > 0 else {
    throw DatabaseRuntimeError.invalidConfiguration(field: "maximumConnections")
  }
  guard options.maximumConnections >= options.minimumConnections else {
    throw DatabaseRuntimeError.invalidConfiguration(field: "maximumConnections")
  }
}
