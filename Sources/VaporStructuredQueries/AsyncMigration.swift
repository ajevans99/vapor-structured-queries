/// A migration that can prepare and revert schema/data changes.
public protocol AsyncMigration: Sendable {
  /// The migration name used for tracking.
  var name: String { get }

  /// Applies the migration.
  ///
  /// - Parameter database: The database to migrate.
  /// - Throws: An error if migration application fails.
  func prepare(on database: any Database) async throws

  /// Reverts the migration.
  ///
  /// - Parameter database: The database to revert.
  /// - Throws: An error if migration revert fails.
  func revert(on database: any Database) async throws
}

extension AsyncMigration {
  /// A default migration name based on the type name.
  public var name: String {
    String(reflecting: Self.self)
  }
}
