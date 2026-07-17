import Logging
import NIOConcurrencyHelpers
import NIOCore

/// A registry that stores database configurations and lazily constructed database instances.
public final class Databases: @unchecked Sendable {
  private struct Storage {
    enum ShutdownState {
      case running
      case shuttingDown([CheckedContinuation<Void, any Error>])
      case complete(Result<Void, any Error>)
    }

    var configurations: [DatabaseID: DatabaseConfigurationFactory] = [:]
    var instances: [DatabaseID: any Database] = [:]
    var defaultID: DatabaseID?
    var isShutdown = false
    var shutdownState = ShutdownState.running
  }

  private let storage = NIOLockedValueBox(Storage())
  private let eventLoopGroup: any EventLoopGroup
  private let backgroundLogger: Logger

  init(on eventLoopGroup: any EventLoopGroup, logger: Logger) {
    self.eventLoopGroup = eventLoopGroup
    self.backgroundLogger = logger
  }

  /// Registers a database configuration for an identifier.
  ///
  /// - Parameters:
  ///   - configurationFactory: The database configuration factory.
  ///   - id: The unique identifier for this configuration.
  /// - Throws: An error if a replaced database cannot shut down.
  public func use(
    _ configurationFactory: DatabaseConfigurationFactory,
    as id: DatabaseID
  ) async throws {
    let existing = try self.storage.withLockedValue { storage in
      guard !storage.isShutdown else {
        throw DatabaseRuntimeError.databaseShutdown
      }
      storage.configurations[id] = configurationFactory
      return storage.instances.removeValue(forKey: id)
    }
    if let existing {
      try await existing.shutdown()
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
      guard !storage.isShutdown else {
        return nil
      }
      let resolvedID = id ?? storage.defaultID
      guard let resolvedID else {
        return nil
      }

      if let existing = storage.instances[resolvedID] {
        return DatabaseHandle(database: existing, logger: logger)
      }

      guard let configuration = storage.configurations[resolvedID] else {
        return nil
      }

      let created = configuration.makeDatabase(self.eventLoopGroup, self.backgroundLogger)
      storage.instances[resolvedID] = created
      return DatabaseHandle(database: created, logger: logger)
    }
  }

  /// Shuts down all resolved databases.
  public func shutdown() async throws {
    enum Action {
      case initiate([any Database])
      case wait
      case complete(Result<Void, any Error>)
    }

    let action = self.storage.withLockedValue { storage -> Action in
      switch storage.shutdownState {
      case .running:
        storage.isShutdown = true
        let instances = Array(storage.instances.values)
        storage.instances = [:]
        storage.shutdownState = .shuttingDown([])
        return .initiate(instances)
      case .shuttingDown:
        return .wait
      case .complete(let result):
        return .complete(result)
      }
    }

    switch action {
    case .initiate(let instances):
      try await self.finishShutdown(of: instances)
    case .wait:
      try await withCheckedThrowingContinuation { continuation in
        let result = self.storage.withLockedValue {
          storage -> Result<Void, any Error>? in
          switch storage.shutdownState {
          case .running:
            preconditionFailure("Database shutdown returned to its running state")
          case .shuttingDown(var continuations):
            continuations.append(continuation)
            storage.shutdownState = .shuttingDown(continuations)
            return nil
          case .complete(let result):
            return result
          }
        }
        if let result {
          continuation.resume(with: result)
        }
      }
    case .complete(let result):
      try result.get()
    }
  }

  private func finishShutdown(of instances: [any Database]) async throws {
    var firstError: (any Error)?
    for database in instances {
      do {
        try await database.shutdown()
      } catch {
        if firstError == nil {
          firstError = error
        }
      }
    }

    let result: Result<Void, any Error> =
      if let firstError {
        .failure(firstError)
      } else {
        .success(())
      }
    let continuations = self.storage.withLockedValue { storage in
      let continuations =
        switch storage.shutdownState {
        case .shuttingDown(let continuations):
          continuations
        case .running, .complete:
          preconditionFailure("Database shutdown completed from an invalid state")
        }
      storage.shutdownState = .complete(result)
      return continuations
    }
    for continuation in continuations {
      continuation.resume(with: result)
    }
    try result.get()
  }
}
