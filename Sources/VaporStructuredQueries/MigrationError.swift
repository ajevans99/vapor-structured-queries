import StructuredQueries

/// A stable database identity captured for migration diagnostics.
public struct MigrationDatabaseSnapshot: Equatable, Sendable {
  /// The configured database identifier, or `nil` for an unresolved default.
  public let id: String?

  /// Creates a database identity snapshot.
  public init(id: String?) {
    self.id = id
  }
}

/// A persisted migration history entry included in migration errors.
public struct AppliedMigrationRecord: Equatable, QueryRepresentable, Sendable {
  public typealias QueryOutput = AppliedMigrationRecord

  /// The migration's stable tracking name.
  public let name: String

  /// The batch in which the migration was applied.
  public let batch: Int64

  /// The persisted application order, or `nil` for a legacy record.
  public let sequence: Int64?

  /// Creates an applied migration record.
  public init(name: String, batch: Int64, sequence: Int64?) {
    self.name = name
    self.batch = batch
    self.sequence = sequence
  }

  public init(queryOutput: AppliedMigrationRecord) {
    self = queryOutput
  }

  public init(decoder: inout some QueryDecoder) throws {
    self.name = try String(decoder: &decoder)
    self.batch = try Int64(decoder: &decoder)
    self.sequence = try Int64?(decoder: &decoder)
  }

  public var queryOutput: AppliedMigrationRecord {
    self
  }
}

/// Errors raised while validating or executing migrations.
public enum MigrationError: Error, Equatable, Sendable {
  /// Multiple registered migrations use the same tracking name.
  case duplicateRegisteredNames(database: MigrationDatabaseSnapshot, names: [String])

  /// Applied migrations are absent from the running binary.
  case unknownAppliedMigrations(
    database: MigrationDatabaseSnapshot,
    migrations: [AppliedMigrationRecord]
  )

  /// Persisted migration history violates an ordering invariant.
  case invalidHistory(database: MigrationDatabaseSnapshot, reason: String)

  /// Mutually exclusive migration command flags were provided.
  case conflictingCommandOptions
}
