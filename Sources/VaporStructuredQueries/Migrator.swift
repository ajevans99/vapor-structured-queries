import Logging
import StructuredQueries

/// Applies and reverts registered migrations.
public struct Migrator: Sendable {
  private let databases: Databases
  private let migrations: Migrations
  private let logger: Logger
  private let migrationLogLevel: Logger.Level

  init(
    databases: Databases,
    migrations: Migrations,
    logger: Logger,
    migrationLogLevel: Logger.Level
  ) {
    self.databases = databases
    self.migrations = migrations
    self.logger = logger
    self.migrationLogLevel = migrationLogLevel
  }

  /// Creates the migration tracking table if needed.
  public func setupIfNeeded() async throws {
    for id in self.orderedIDs() {
      guard let database = self.databases.database(id, logger: self.logger) else {
        throw DatabaseRuntimeError.missingConfiguredDatabase(id)
      }
      try await database.execute(
        #sql(
          """
          CREATE TABLE IF NOT EXISTS "_database_migrations" (
            "name" TEXT PRIMARY KEY,
            "batch" BIGINT NOT NULL
          )
          """,
          as: Void.self
        )
      )
    }
  }

  /// Applies all pending migrations in a new batch.
  public func prepareBatch() async throws {
    for id in self.orderedIDs() {
      guard let database = self.databases.database(id, logger: self.logger) else {
        throw DatabaseRuntimeError.missingConfiguredDatabase(id)
      }

      let registered = self.migrations.migrations(for: id)
      guard !registered.isEmpty else {
        continue
      }

      let prepared = Set(
        try await database.all(
          #sql(
            "SELECT \"name\" FROM \"_database_migrations\"",
            as: String.self
          )
        )
      )

      let pending = registered.filter { !prepared.contains($0.name) }
      guard !pending.isEmpty else {
        continue
      }

      let batch = Int64(
        try await database.first(
          #sql(
            "SELECT COALESCE(MAX(\"batch\"), 0) + 1 FROM \"_database_migrations\"",
            as: Int.self
          )
        ) ?? 1
      )

      for migration in pending {
        self.log("Preparing migration \(migration.name) on \(id?.string ?? "<default>")")
        try await migration.prepare(on: database)
        try await database.execute(
          #sql(
            "INSERT INTO \"_database_migrations\" (\"name\", \"batch\") VALUES (\(bind: migration.name), \(bind: batch))",
            as: Void.self
          )
        )
      }
    }
  }

  /// Reverts all prepared migrations in reverse order.
  public func revertAllBatches() async throws {
    for id in self.orderedIDs() {
      guard let database = self.databases.database(id, logger: self.logger) else {
        throw DatabaseRuntimeError.missingConfiguredDatabase(id)
      }

      let registered = self.migrations.migrations(for: id)
      guard !registered.isEmpty else {
        continue
      }

      let byName = Dictionary(uniqueKeysWithValues: registered.map { ($0.name, $0) })
      let prepared = try await database.all(
        #sql(
          "SELECT \"name\" FROM \"_database_migrations\" ORDER BY \"batch\" DESC, \"name\" DESC",
          as: String.self
        )
      )

      for name in prepared {
        guard let migration = byName[name] else {
          self.log("Skipping unknown migration \(name) on \(id?.string ?? "<default>")")
          try await database.execute(
            #sql(
              "DELETE FROM \"_database_migrations\" WHERE \"name\" = \(bind: name)",
              as: Void.self
            )
          )
          continue
        }

        self.log("Reverting migration \(migration.name) on \(id?.string ?? "<default>")")
        try await migration.revert(on: database)
        try await database.execute(
          #sql(
            "DELETE FROM \"_database_migrations\" WHERE \"name\" = \(bind: migration.name)",
            as: Void.self
          )
        )
      }
    }
  }

  private func orderedIDs() -> [DatabaseID?] {
    self.migrations.ids().sorted { lhs, rhs in
      switch (lhs, rhs) {
      case (nil, nil):
        return false
      case (nil, _):
        return true
      case (_, nil):
        return false
      case (.some(let lhs), .some(let rhs)):
        return lhs.string < rhs.string
      }
    }
  }

  private func log(_ message: String) {
    self.logger.log(level: self.migrationLogLevel, "\(message)")
  }
}
