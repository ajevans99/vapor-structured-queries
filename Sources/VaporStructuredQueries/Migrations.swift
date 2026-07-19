import NIOConcurrencyHelpers

/// A registry of migrations keyed by optional database identifier.
public final class Migrations: Sendable {
  private struct Registration: Sendable {
    let migration: any AsyncMigration
    let order: Int
  }

  private struct Storage: Sendable {
    var registrations: [DatabaseID?: [Registration]] = [:]
    var nextOrder = 0
  }

  private let storage = NIOLockedValueBox(Storage())

  /// Creates an empty migration registry.
  public init() {}

  /// Adds a migration to the registry.
  ///
  /// - Parameters:
  ///   - migration: The migration to add.
  ///   - id: An optional database identifier. `nil` means default database.
  public func add(_ migration: any AsyncMigration, to id: DatabaseID? = nil) {
    self.storage.withLockedValue { storage in
      storage.registrations[id, default: []].append(
        Registration(migration: migration, order: storage.nextOrder)
      )
      storage.nextOrder += 1
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
    self.storage.withLockedValue { storage in
      for migration in migrations {
        storage.registrations[id, default: []].append(
          Registration(migration: migration, order: storage.nextOrder)
        )
        storage.nextOrder += 1
      }
    }
  }

  func migrations(for id: DatabaseID?, defaultID: DatabaseID?) -> [any AsyncMigration] {
    self.storage.withLockedValue { storage in
      var registrations = id.flatMap { storage.registrations[$0] } ?? []
      if let id, id == defaultID {
        registrations.append(contentsOf: storage.registrations[nil] ?? [])
      } else if id == nil {
        registrations = storage.registrations[nil] ?? []
      }
      return registrations.sorted { $0.order < $1.order }.map(\.migration)
    }
  }

  func ids() -> [DatabaseID?] {
    self.storage.withLockedValue { Array($0.registrations.keys) }
  }
}
