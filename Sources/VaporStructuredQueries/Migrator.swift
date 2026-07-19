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

  /// Creates or upgrades migration tracking tables under the migration lock.
  public func setupIfNeeded() async throws {
    for target in self.targets() {
      let (database, registered) = try self.databaseAndMigrations(for: target)
      try self.validateRegistration(registered, databaseID: target)
      try await database.withMigrationLock { transaction in
        _ = try await self.loadHistory(
          on: transaction,
          registered: registered,
          databaseID: target
        )
      }
    }
  }

  /// Applies all pending migrations in registration order as a new batch.
  public func prepareBatch() async throws {
    for target in self.targets() {
      let (database, registered) = try self.databaseAndMigrations(for: target)
      try self.validateRegistration(registered, databaseID: target)
      try await database.withMigrationLock { transaction in
        let history = try await self.loadHistory(
          on: transaction,
          registered: registered,
          databaseID: target
        )
        let appliedNames = Set(history.map(\.name))
        let pending = registered.filter { !appliedNames.contains($0.name) }
        guard !pending.isEmpty else { return }

        let maximumBatch = history.map(\.batch).max() ?? 0
        let maximumSequence = history.compactMap(\.sequence).max() ?? 0
        guard maximumBatch < .max, maximumSequence < .max else {
          throw MigrationError.invalidHistory(
            database: Self.snapshot(target),
            reason: "Migration batch or sequence has reached the maximum 64-bit value."
          )
        }
        let batch = maximumBatch + 1
        var sequence = maximumSequence + 1
        for migration in pending {
          try Task.checkCancellation()
          self.log("Preparing migration \(migration.name) on \(target?.string ?? "<default>")")
          try await migration.prepare(on: transaction)
          try Task.checkCancellation()
          try await transaction.execute(
            #sql(
              """
              INSERT INTO "_database_migrations" ("name", "batch", "sequence")
              VALUES (\(bind: migration.name), \(bind: batch), \(bind: sequence))
              """,
              as: Void.self
            )
          )
          sequence += 1
        }
      }
    }
  }

  /// Reverts the latest applied migration batch in exact reverse application order.
  public func revertLastBatch() async throws {
    try await self.revert(.latest)
  }

  /// Reverts every applied migration in exact reverse application order.
  public func revertAllBatches() async throws {
    try await self.revert(.all)
  }

  private enum RevertScope {
    case latest
    case all
  }

  private func revert(_ scope: RevertScope) async throws {
    for target in self.targets() {
      let (database, registered) = try self.databaseAndMigrations(for: target)
      try self.validateRegistration(registered, databaseID: target)
      try await database.withMigrationLock { transaction in
        let history = try await self.loadHistory(
          on: transaction,
          registered: registered,
          databaseID: target
        )
        let selected: [AppliedMigrationRecord]
        switch scope {
        case .latest:
          guard let latestBatch = history.map(\.batch).max() else { return }
          selected = history.filter { $0.batch == latestBatch }
        case .all:
          selected = history
        }
        let byName = Dictionary(uniqueKeysWithValues: registered.map { ($0.name, $0) })
        for record in selected.sorted(by: Self.reverseApplicationOrder) {
          try Task.checkCancellation()
          guard let migration = byName[record.name] else {
            preconditionFailure("History was validated before reversion")
          }
          self.log("Reverting migration \(migration.name) on \(target?.string ?? "<default>")")
          try await migration.revert(on: transaction)
          try Task.checkCancellation()
          try await transaction.execute(
            #sql(
              "DELETE FROM \"_database_migrations\" WHERE \"name\" = \(bind: migration.name)",
              as: Void.self
            )
          )
        }
      }
    }
  }

  private func loadHistory(
    on database: any Database,
    registered: [any AsyncMigration],
    databaseID: DatabaseID?
  ) async throws -> [AppliedMigrationRecord] {
    switch database.migrationDialect {
    case .postgres:
      return try await self.loadPostgresHistory(
        on: database,
        registered: registered,
        databaseID: databaseID
      )
    case .sqlite:
      return try await self.loadSQLiteHistory(
        on: database,
        registered: registered,
        databaseID: databaseID
      )
    case .unsupported:
      throw DatabaseRuntimeError.unsupportedOperation(.migrationLock)
    }
  }

  private func loadPostgresHistory(
    on database: any Database,
    registered: [any AsyncMigration],
    databaseID: DatabaseID?
  ) async throws -> [AppliedMigrationRecord] {
    try await database.execute(
      #sql(
        """
        CREATE TABLE IF NOT EXISTS "_database_migrations" (
          "name" TEXT PRIMARY KEY,
          "batch" BIGINT NOT NULL,
          "sequence" BIGINT
        )
        """,
        as: Void.self
      )
    )
    try await database.execute(
      #sql(
        """
        ALTER TABLE "_database_migrations"
        ADD COLUMN IF NOT EXISTS "sequence" BIGINT
        """,
        as: Void.self
      )
    )

    let loaded = try await database.all(
      #sql(
        """
        SELECT "name", "batch", "sequence"
        FROM "_database_migrations"
        ORDER BY "batch" ASC, "name" ASC
        """,
        as: AppliedMigrationRecord.self
      )
    )

    let (history, inferred) = try self.validateAndInfer(
      loaded,
      registered: registered,
      databaseID: databaseID
    )
    if inferred {
      for index in history.indices {
        guard let sequence = history[index].sequence else {
          throw MigrationError.invalidHistory(
            database: Self.snapshot(databaseID),
            reason: "Inferred migration sequence was unexpectedly absent."
          )
        }
        try await database.execute(
          #sql(
            """
            UPDATE "_database_migrations"
            SET "sequence" = \(bind: sequence)
            WHERE "name" = \(bind: history[index].name)
            """,
            as: Void.self
          )
        )
      }
    }

    try await database.execute(
      #sql(
        """
        ALTER TABLE "_database_migrations"
        ALTER COLUMN "sequence" SET NOT NULL
        """,
        as: Void.self
      )
    )
    try await database.execute(
      #sql(
        """
        CREATE UNIQUE INDEX IF NOT EXISTS "_database_migrations_sequence_key"
        ON "_database_migrations" ("sequence")
        """,
        as: Void.self
      )
    )
    if inferred {
      self.logLegacyInferenceWarning(databaseID: databaseID)
    }
    return history
  }

  private func loadSQLiteHistory(
    on database: any Database,
    registered: [any AsyncMigration],
    databaseID: DatabaseID?
  ) async throws -> [AppliedMigrationRecord] {
    let tableExists =
      try await database.first(
        #sql(
          """
          SELECT EXISTS (
            SELECT 1 FROM "sqlite_master"
            WHERE "type" = 'table' AND "name" = '_database_migrations'
          )
          """,
          as: Bool.self
        )
      ) ?? false
    guard tableExists else {
      try await self.createSQLiteTable(on: database, named: "_database_migrations")
      return []
    }

    let hasSequence =
      (try await database.first(
        #sql(
          """
          SELECT COUNT(*) FROM pragma_table_info('_database_migrations')
          WHERE "name" = 'sequence'
          """,
          as: Int.self
        )
      ) ?? 0) == 1
    let sequenceIsNotNull: Bool
    if hasSequence {
      sequenceIsNotNull =
        (try await database.first(
          #sql(
            """
            SELECT "notnull" FROM pragma_table_info('_database_migrations')
            WHERE "name" = 'sequence'
            """,
            as: Int.self
          )
        ) ?? 0) == 1
    } else {
      sequenceIsNotNull = false
    }

    let loaded: [AppliedMigrationRecord]
    if hasSequence {
      loaded = try await database.all(
        #sql(
          """
          SELECT "name", "batch", "sequence"
          FROM "_database_migrations"
          ORDER BY "batch" ASC, "name" ASC
          """,
          as: AppliedMigrationRecord.self
        )
      )
    } else {
      loaded = try await database.all(
        #sql(
          """
          SELECT "name", "batch"
          FROM "_database_migrations"
          ORDER BY "batch" ASC, "name" ASC
          """,
          as: LegacyMigrationRecord.self
        )
      )
      .map(\.record)
    }

    let (history, inferred) = try self.validateAndInfer(
      loaded,
      registered: registered,
      databaseID: databaseID
    )
    if !hasSequence || !sequenceIsNotNull {
      try await self.rebuildSQLiteHistory(history, on: database, databaseID: databaseID)
    } else {
      try await database.execute(
        #sql(
          """
          CREATE UNIQUE INDEX IF NOT EXISTS "_database_migrations_sequence_key"
          ON "_database_migrations" ("sequence")
          """,
          as: Void.self
        )
      )
    }
    if inferred {
      self.logLegacyInferenceWarning(databaseID: databaseID)
    }
    return history
  }

  private func createSQLiteTable(
    on database: any Database,
    named name: String,
    createSequenceIndex: Bool = true
  ) async throws {
    try await database.execute(
      #sql(
        """
        CREATE TABLE \(quote: name) (
          "name" TEXT PRIMARY KEY,
          "batch" INTEGER NOT NULL,
          "sequence" INTEGER NOT NULL
        )
        """,
        as: Void.self
      )
    )
    if createSequenceIndex {
      try await database.execute(
        #sql(
          """
          CREATE UNIQUE INDEX "_database_migrations_sequence_key"
          ON \(quote: name) ("sequence")
          """,
          as: Void.self
        )
      )
    }
  }

  private func rebuildSQLiteHistory(
    _ history: [AppliedMigrationRecord],
    on database: any Database,
    databaseID: DatabaseID?
  ) async throws {
    try await database.execute(
      #sql("DROP TABLE IF EXISTS \"_database_migrations_upgrade\"", as: Void.self)
    )
    try await self.createSQLiteTable(
      on: database,
      named: "_database_migrations_upgrade",
      createSequenceIndex: false
    )
    for record in history {
      guard let sequence = record.sequence else {
        throw MigrationError.invalidHistory(
          database: Self.snapshot(databaseID),
          reason: "SQLite migration history sequence was unexpectedly absent."
        )
      }
      try await database.execute(
        #sql(
          """
          INSERT INTO "_database_migrations_upgrade" ("name", "batch", "sequence")
          VALUES (\(bind: record.name), \(bind: record.batch), \(bind: sequence))
          """,
          as: Void.self
        )
      )
    }
    let copiedCount =
      try await database.first(
        #sql("SELECT COUNT(*) FROM \"_database_migrations_upgrade\"", as: Int.self)
      ) ?? 0
    guard copiedCount == history.count else {
      throw MigrationError.invalidHistory(
        database: Self.snapshot(databaseID),
        reason: "SQLite migration history copy count did not match the source table."
      )
    }
    try await database.execute(#sql("DROP TABLE \"_database_migrations\"", as: Void.self))
    try await database.execute(
      #sql(
        """
        ALTER TABLE "_database_migrations_upgrade"
        RENAME TO "_database_migrations"
        """,
        as: Void.self
      )
    )
    try await database.execute(
      #sql(
        """
        CREATE UNIQUE INDEX "_database_migrations_sequence_key"
        ON "_database_migrations" ("sequence")
        """,
        as: Void.self
      )
    )
  }

  private func validateAndInfer(
    _ loaded: [AppliedMigrationRecord],
    registered: [any AsyncMigration],
    databaseID: DatabaseID?
  ) throws -> (history: [AppliedMigrationRecord], inferred: Bool) {
    let registeredNames = Set(registered.map(\.name))
    let unknown = loaded.filter { !registeredNames.contains($0.name) }
    guard unknown.isEmpty else {
      throw MigrationError.unknownAppliedMigrations(
        database: Self.snapshot(databaseID),
        migrations: unknown
      )
    }
    guard loaded.allSatisfy({ $0.batch > 0 }) else {
      throw MigrationError.invalidHistory(
        database: Self.snapshot(databaseID),
        reason: "Migration batch values must be positive."
      )
    }

    let sequencedCount = loaded.count { $0.sequence != nil }
    guard sequencedCount == 0 || sequencedCount == loaded.count else {
      throw MigrationError.invalidHistory(
        database: Self.snapshot(databaseID),
        reason: "Migration sequence values are only partially populated."
      )
    }

    var history = loaded
    let inferred = !history.isEmpty && sequencedCount == 0
    if inferred {
      let registrationOrder = Dictionary(
        uniqueKeysWithValues: registered.enumerated().map { ($0.element.name, $0.offset) }
      )
      guard history.allSatisfy({ registrationOrder[$0.name] != nil }) else {
        throw MigrationError.invalidHistory(
          database: Self.snapshot(databaseID),
          reason: "Legacy migration names could not be mapped to current registration order."
        )
      }
      history.sort {
        if $0.batch != $1.batch { return $0.batch < $1.batch }
        return registrationOrder[$0.name, default: .max]
          < registrationOrder[$1.name, default: .max]
      }
      history = history.enumerated().map {
        AppliedMigrationRecord(
          name: $0.element.name,
          batch: $0.element.batch,
          sequence: Int64($0.offset + 1)
        )
      }
    }

    let sequences = history.compactMap(\.sequence)
    guard sequences.allSatisfy({ $0 > 0 }), Set(sequences).count == sequences.count else {
      throw MigrationError.invalidHistory(
        database: Self.snapshot(databaseID),
        reason: "Migration sequence values must be positive and unique."
      )
    }
    let applicationOrder = history.sorted {
      ($0.sequence ?? .min) < ($1.sequence ?? .min)
    }
    guard
      zip(applicationOrder, applicationOrder.dropFirst()).allSatisfy({
        $0.batch <= $1.batch
      })
    else {
      throw MigrationError.invalidHistory(
        database: Self.snapshot(databaseID),
        reason: "Migration batches must not decrease in persisted application order."
      )
    }
    return (history, inferred)
  }

  private func logLegacyInferenceWarning(databaseID: DatabaseID?) {
    self.logger.warning(
      """
      Legacy migration order on \(databaseID?.string ?? "<default>") was inferred from current \
      registration order, not validated. Already-applied migrations must not have been reordered; \
      reordered known names are undetectable from legacy records.
      """
    )
  }

  private func databaseAndMigrations(
    for id: DatabaseID?
  ) throws -> (any Database, [any AsyncMigration]) {
    guard let database = self.databases.database(id, logger: self.logger) else {
      throw DatabaseRuntimeError.missingConfiguredDatabase(id)
    }
    let defaultID = self.databases.defaultDatabaseID()
    return (database, self.migrations.migrations(for: id, defaultID: defaultID))
  }

  private func validateRegistration(
    _ registered: [any AsyncMigration],
    databaseID: DatabaseID?
  ) throws {
    let counts = Dictionary(grouping: registered.map(\.name), by: { $0 })
    let duplicates = counts.compactMap { $0.value.count > 1 ? $0.key : nil }.sorted()
    guard duplicates.isEmpty else {
      throw MigrationError.duplicateRegisteredNames(
        database: Self.snapshot(databaseID),
        names: duplicates
      )
    }
  }

  private func targets() -> [DatabaseID?] {
    let defaultID = self.databases.defaultDatabaseID()
    var targets: Set<DatabaseID?> = []
    for id in self.migrations.ids() {
      if let id {
        targets.insert(id)
      } else if let defaultID {
        targets.insert(defaultID)
      } else {
        targets.insert(nil)
      }
    }
    if targets.isEmpty {
      targets.insert(defaultID)
    }
    return targets.sorted(by: Self.databaseOrder)
  }

  private static func databaseOrder(_ lhs: DatabaseID?, _ rhs: DatabaseID?) -> Bool {
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

  private static func reverseApplicationOrder(
    _ lhs: AppliedMigrationRecord,
    _ rhs: AppliedMigrationRecord
  ) -> Bool {
    (lhs.sequence ?? .min) > (rhs.sequence ?? .min)
  }

  private static func snapshot(_ databaseID: DatabaseID?) -> MigrationDatabaseSnapshot {
    MigrationDatabaseSnapshot(id: databaseID?.string)
  }

  private func log(_ message: String) {
    self.logger.log(level: self.migrationLogLevel, "\(message)")
  }
}

private struct LegacyMigrationRecord: QueryRepresentable {
  typealias QueryOutput = LegacyMigrationRecord

  let name: String
  let batch: Int64

  init(queryOutput: LegacyMigrationRecord) {
    self = queryOutput
  }

  init(decoder: inout some QueryDecoder) throws {
    self.name = try String(decoder: &decoder)
    self.batch = try Int64(decoder: &decoder)
  }

  var queryOutput: LegacyMigrationRecord {
    self
  }

  var record: AppliedMigrationRecord {
    AppliedMigrationRecord(name: self.name, batch: self.batch, sequence: nil)
  }
}
