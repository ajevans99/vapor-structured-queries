import NIOConcurrencyHelpers

/// A registry of migrations keyed by optional database identifier.
public final class Migrations: Sendable {
  private let storage = NIOLockedValueBox([DatabaseID?: [any AsyncMigration]]())

  /// Creates an empty migration registry.
  public init() {}

  /// Adds a migration to the registry.
  ///
  /// - Parameters:
  ///   - migration: The migration to add.
  ///   - id: An optional database identifier. `nil` means default database.
  public func add(_ migration: any AsyncMigration, to id: DatabaseID? = nil) {
    self.storage.withLockedValue {
      $0[id, default: []].append(migration)
    }
  }

  /// Adds variadic migrations to the registry.
  ///
  /// - Parameters:
  ///   - migrations: Migrations to add.
  ///   - id: An optional database identifier.
  public func add(_ migrations: any AsyncMigration..., to id: DatabaseID? = nil) {
    self.add(migrations, to: id)
  }

  /// Adds an array of migrations to the registry.
  ///
  /// - Parameters:
  ///   - migrations: Migrations to add.
  ///   - id: An optional database identifier.
  public func add(_ migrations: [any AsyncMigration], to id: DatabaseID? = nil) {
    self.storage.withLockedValue {
      $0[id, default: []].append(contentsOf: migrations)
    }
  }

  func migrations(for id: DatabaseID?) -> [any AsyncMigration] {
    self.storage.withLockedValue { $0[id] ?? [] }
  }

  func ids() -> [DatabaseID?] {
    self.storage.withLockedValue { Array($0.keys) }
  }
}
