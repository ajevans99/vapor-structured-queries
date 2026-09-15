import Logging
import NIOConcurrencyHelpers
import StructuredQueries
import Vapor

extension Request {
  #if !FluentCompatibility
    /// The default database for this request.
    public var db: any Database {
      self.db(nil)
    }

    /// Resolves a database for this request.
    ///
    /// - Parameter id: The optional database identifier.
    /// - Returns: The resolved database.
    public func db(_ id: DatabaseID?) -> any Database {
      self.db(id, logger: self.logger)
    }

    /// Resolves a database for this request with a custom logger.
    ///
    /// - Parameters:
    ///   - id: The optional database identifier.
    ///   - logger: The logger used for resolution.
    /// - Returns: The resolved database.
    public func db(_ id: DatabaseID?, logger: Logger) -> any Database {
      self.structuredQueriesDB(id, logger: logger)
    }
  #endif

  /// The default StructuredQueries database for this request.
  public var structuredQueriesDB: any Database {
    self.structuredQueriesDB(nil)
  }

  /// Resolves a StructuredQueries database by identifier using the request logger.
  public func structuredQueriesDB(_ id: DatabaseID?) -> any Database {
    self.structuredQueriesDB(id, logger: self.logger)
  }

  /// Resolves a StructuredQueries database by identifier with a custom logger.
  public func structuredQueriesDB(_ id: DatabaseID?, logger: Logger) -> any Database {
    self.application.structuredQueriesDB(id, logger: logger)
  }
}

extension Application {
  #if !FluentCompatibility
    /// The default database for this application.
    public var db: any Database {
      self.db(nil)
    }

    /// Resolves a database for this application.
    ///
    /// - Parameter id: The optional database identifier.
    /// - Returns: The resolved database.
    public func db(_ id: DatabaseID?) -> any Database {
      self.db(id, logger: self.logger)
    }

    /// Resolves a database for this application with a custom logger.
    ///
    /// - Parameters:
    ///   - id: The optional database identifier.
    ///   - logger: The logger used for resolution.
    /// - Returns: The resolved database.
    public func db(_ id: DatabaseID?, logger: Logger) -> any Database {
      self.structuredQueriesDB(id, logger: logger)
    }

    /// All configured database registries for this application.
    public var databases: Databases { self.structuredQueriesDatabases }

    /// The migration registry for this application.
    public var migrations: Migrations { self.structuredQueriesMigrations }

    /// The migrator for this application.
    public var migrator: Migrator { self.structuredQueriesMigrator }

    /// Runs all pending migrations.
    public func autoMigrate() async throws { try await self.structuredQueriesAutoMigrate() }

    /// Reverts all prepared migrations.
    public func autoRevert() async throws { try await self.structuredQueriesAutoRevert() }
  #endif

  /// The default StructuredQueries database for this application.
  public var structuredQueriesDB: any Database {
    self.structuredQueriesDB(nil)
  }

  /// Resolves a StructuredQueries database by identifier using the application logger.
  public func structuredQueriesDB(_ id: DatabaseID?) -> any Database {
    self.structuredQueriesDB(id, logger: self.logger)
  }

  /// Resolves a StructuredQueries database by identifier with a custom logger.
  public func structuredQueriesDB(_ id: DatabaseID?, logger: Logger) -> any Database {
    if let database = self.structuredQueriesDatabases.database(id, logger: logger) {
      return database
    }

    let reason: String
    if let id {
      reason = "No database is configured for id \(id.string)."
    } else {
      reason =
        "No default database is configured. Call app.database.use(..., as:) and app.database.default(to:)."
    }
    return UnconfiguredDatabase(reason: reason)
  }

  /// All configured database registries for this application.
  public var structuredQueriesDatabases: Databases {
    self.database.storage.databases
  }

  /// The migration registry for this application.
  public var structuredQueriesMigrations: Migrations {
    self.database.storage.migrations
  }

  /// The migrator for this application.
  public var structuredQueriesMigrator: Migrator {
    .init(
      databases: self.structuredQueriesDatabases,
      migrations: self.structuredQueriesMigrations,
      logger: self.logger,
      migrationLogLevel: self.database.migrationLogLevel
    )
  }

  /// Runs all pending migrations.
  public func structuredQueriesAutoMigrate() async throws {
    try await self.structuredQueriesMigrator.setupIfNeeded()
    try await self.structuredQueriesMigrator.prepareBatch()
  }

  /// Reverts all prepared migrations.
  public func structuredQueriesAutoRevert() async throws {
    try await self.structuredQueriesMigrator.setupIfNeeded()
    try await self.structuredQueriesMigrator.revertAllBatches()
  }

  /// The VaporStructuredQueries application namespace.
  public struct DatabaseContext {
    final class Storage: Sendable {
      let databases: Databases
      let migrations: Migrations
      let migrationLogLevel: NIOLockedValueBox<Logger.Level>

      init(on eventLoopGroup: any EventLoopGroup, migrationLogLevel: Logger.Level) {
        self.databases = Databases(on: eventLoopGroup)
        self.migrations = .init()
        self.migrationLogLevel = .init(migrationLogLevel)
      }
    }

    struct Key: StorageKey {
      typealias Value = Storage
    }

    struct Lifecycle: LifecycleHandler {
      struct Signature: CommandSignature {
        @Flag(
          name: "auto-migrate",
          help: "If true, VaporStructuredQueries will automatically migrate your database on boot"
        )
        var autoMigrate: Bool

        @Flag(
          name: "auto-revert",
          help: "If true, VaporStructuredQueries will automatically revert your database on boot"
        )
        var autoRevert: Bool
      }

      func willBoot(_ application: Application) throws {
        let signature = try Signature(from: &application.environment.commandInput)

        if signature.autoRevert {
          try application.eventLoopGroup.any().makeFutureWithTask {
            try await application.structuredQueriesAutoRevert()
          }.wait()
        }
        if signature.autoMigrate {
          try application.eventLoopGroup.any().makeFutureWithTask {
            try await application.structuredQueriesAutoMigrate()
          }.wait()
        }
      }

      func willBootAsync(_ application: Application) async throws {
        let signature = try Signature(from: &application.environment.commandInput)

        if signature.autoRevert {
          try await application.structuredQueriesAutoRevert()
        }
        if signature.autoMigrate {
          try await application.structuredQueriesAutoMigrate()
        }
      }

      func shutdown(_ application: Application) {
        application.structuredQueriesDatabases.shutdown()
      }

      func shutdownAsync(_ application: Application) async {
        application.structuredQueriesDatabases.shutdown()
      }
    }

    let application: Application

    var storage: Storage {
      if self.application.storage[Key.self] == nil {
        self.initialize()
      }
      return self.application.storage[Key.self]!
    }

    func initialize() {
      self.application.storage[Key.self] = .init(
        on: self.application.eventLoopGroup,
        migrationLogLevel: .info
      )
      self.application.lifecycle.use(Lifecycle())
      self.application.asyncCommands.use(MigrateCommand(), as: "migrate")
    }

    /// Registers a database configuration.
    ///
    /// - Parameters:
    ///   - configurationFactory: The configuration factory.
    ///   - id: The database identifier.
    public func use(_ configurationFactory: DatabaseConfigurationFactory, as id: DatabaseID) {
      self.storage.databases.use(configurationFactory, as: id)
    }

    /// Sets the default database identifier.
    ///
    /// - Parameter id: The database identifier.
    public func `default`(to id: DatabaseID) {
      self.storage.databases.default(to: id)
    }

    /// Controls migrator log verbosity.
    public var migrationLogLevel: Logger.Level {
      get { self.storage.migrationLogLevel.withLockedValue { $0 } }
      nonmutating set { self.storage.migrationLogLevel.withLockedValue { $0 = newValue } }
    }
  }

  /// The VaporStructuredQueries namespace for configuring databases and migrations.
  public var database: DatabaseContext {
    let context = DatabaseContext(application: self)
    _ = context.storage
    return context
  }
}

private struct UnconfiguredDatabase: Database {
  let reason: String

  func all<S: Statement>(_ statement: S) async throws -> [S.QueryValue.QueryOutput]
  where S.QueryValue: QueryRepresentable, S.QueryValue.QueryOutput: Sendable {
    throw Abort(.internalServerError, reason: self.reason)
  }

  func first<S: Statement>(_ statement: S) async throws -> S.QueryValue.QueryOutput?
  where S.QueryValue: QueryRepresentable, S.QueryValue.QueryOutput: Sendable {
    throw Abort(.internalServerError, reason: self.reason)
  }

  func execute(_ statement: some Statement<()>) async throws {
    throw Abort(.internalServerError, reason: self.reason)
  }

  func shutdown() {}
}
