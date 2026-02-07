import StructuredQueriesPostgresNIO
import VaporStructuredQueries

extension DatabaseConfigurationFactory {
  /// Creates a Postgres-backed database configuration factory.
  ///
  /// - Parameter configuration: The Postgres client configuration.
  /// - Returns: A database configuration factory.
  public static func postgres(configuration: PostgresClient.Configuration) -> Self {
    .init { eventLoopGroup, logger in
      PostgresDatabase(
        configuration: configuration,
        eventLoopGroup: eventLoopGroup,
        logger: logger
      )
    }
  }

  /// Creates a Postgres-backed database configuration factory from connection values.
  ///
  /// - Parameters:
  ///   - hostname: Postgres server hostname.
  ///   - port: Postgres server port.
  ///   - username: Postgres username.
  ///   - password: Optional Postgres password.
  ///   - database: Optional database name.
  ///   - tls: TLS configuration.
  /// - Returns: A database configuration factory.
  public static func postgres(
    hostname: String,
    port: Int = 5432,
    username: String,
    password: String?,
    database: String?,
    tls: PostgresClient.Configuration.TLS = .disable
  ) -> Self {
    .postgres(
      configuration: .init(
        host: hostname,
        port: port,
        username: username,
        password: password,
        database: database,
        tls: tls
      )
    )
  }
}
