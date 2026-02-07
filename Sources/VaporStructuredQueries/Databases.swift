import Logging
import NIOConcurrencyHelpers
import NIOCore

/// A registry that stores database configurations and lazily constructed database instances.
public final class Databases: @unchecked Sendable {
  private struct Storage {
    var configurations: [DatabaseID: DatabaseConfigurationFactory] = [:]
    var instances: [DatabaseID: any Database] = [:]
    var defaultID: DatabaseID?
  }

  private let storage = NIOLockedValueBox(Storage())
  private let eventLoopGroup: any EventLoopGroup

  init(on eventLoopGroup: any EventLoopGroup) {
    self.eventLoopGroup = eventLoopGroup
  }

  /// Registers a database configuration for an identifier.
  ///
  /// - Parameters:
  ///   - configurationFactory: The database configuration factory.
  ///   - id: The unique identifier for this configuration.
  public func use(_ configurationFactory: DatabaseConfigurationFactory, as id: DatabaseID) {
    self.storage.withLockedValue {
      $0.configurations[id] = configurationFactory
      $0.instances[id]?.shutdown()
      $0.instances[id] = nil
    }
  }

  /// Sets the default database identifier.
  ///
  /// - Parameter id: The default database identifier.
  public func `default`(to id: DatabaseID) {
    self.storage.withLockedValue {
      $0.defaultID = id
    }
  }

  /// Resolves a configured database instance.
  ///
  /// - Parameters:
  ///   - id: The optional database identifier. When `nil`, the default database is used.
  ///   - logger: A logger used when constructing the database.
  /// - Returns: A resolved database if configuration exists.
  public func database(_ id: DatabaseID? = nil, logger: Logger) -> (any Database)? {
    self.storage.withLockedValue { storage in
      let resolvedID = id ?? storage.defaultID
      guard let resolvedID else {
        return nil
      }

      if let existing = storage.instances[resolvedID] {
        return existing
      }

      guard let configuration = storage.configurations[resolvedID] else {
        return nil
      }

      let created = configuration.makeDatabase(self.eventLoopGroup, logger)
      storage.instances[resolvedID] = created
      return created
    }
  }

  /// Shuts down all resolved databases.
  public func shutdown() {
    let instances = self.storage.withLockedValue { storage in
      let instances = Array(storage.instances.values)
      storage.instances = [:]
      return instances
    }

    for database in instances {
      database.shutdown()
    }
  }
}
