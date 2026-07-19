import Logging
import NIOConcurrencyHelpers
import NIOCore
import StructuredQueriesPostgresNIO
import VaporStructuredQueries

final class PostgresDatabase: Database {
  let logger: Logger
  let migrationDialect = DatabaseMigrationDialect.postgres

  private let client: PostgresClient
  private let lifecycle = PostgresDatabaseLifecycle()
  private let runTask: Task<Void, Never>

  init(
    configuration: PostgresClient.Configuration,
    eventLoopGroup: any EventLoopGroup,
    logger: Logger
  ) {
    let client = PostgresClient(
      configuration: configuration,
      eventLoopGroup: eventLoopGroup,
      backgroundLogger: logger
    )
    self.client = client
    self.logger = logger
    self.runTask = Task {
      await client.run()
    }
  }

  deinit {
    self.runTask.cancel()
  }

  func stream<S: Statement>(
    _ statement: S,
    context: DatabaseExecutionContext
  ) async throws -> DatabaseRowStream<S.QueryValue.QueryOutput>
  where
    S.QueryValue: QueryRepresentable,
    S.QueryValue.QueryOutput: Sendable
  {
    let lease = try self.lifecycle.beginOperation()
    do {
      let rows = try await self.client.query(
        PostgresSendableStatement<S.QueryValue>(query: statement.query),
        logger: context.logger,
        file: context.file,
        line: context.line
      )
      return DatabaseRowStream(rows) {
        lease.release()
      }
    } catch {
      lease.release()
      throw error
    }
  }

  func execute<S: Statement>(
    _ statement: S,
    context: DatabaseExecutionContext
  ) async throws -> DatabaseCommandMetadata?
  where S.QueryValue == () {
    let lease = try self.lifecycle.beginOperation()
    defer { lease.release() }
    return try await self.client.execute(
      statement,
      logger: context.logger,
      file: context.file,
      line: context.line
    )
    .map(DatabaseCommandMetadata.init)
  }

  func withConnection<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    let lease = try self.lifecycle.beginOperation()
    defer { lease.release() }
    return try await self.client.withConnection(isolation: isolation) { connection in
      let validity = PostgresConnectionHandleValidity()
      let database = PostgresConnectionDatabase(
        connection: connection,
        logger: context.logger,
        state: .leased,
        validity: validity
      )
      do {
        let result = try await operation(database)
        await validity.invalidateAndWait()
        return result
      } catch {
        await validity.invalidateAndWait()
        throw error
      }
    }
  }

  func withTransaction<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    let lease = try self.lifecycle.beginOperation()
    defer { lease.release() }
    context.logger.debug("Beginning database transaction")
    do {
      let result = try await self.client.withConnection(isolation: isolation) { connection in
        do {
          return try await connection.withTransaction(
            logger: context.logger,
            file: context.file,
            line: context.line,
            isolation: isolation
          ) { connection in
            let validity = PostgresConnectionHandleValidity()
            let database = PostgresConnectionDatabase(
              connection: connection,
              logger: context.logger,
              state: .transaction,
              validity: validity
            )
            do {
              let result = try await operation(database)
              await validity.invalidateAndWait()
              return result
            } catch {
              await validity.invalidateAndWait()
              throw error
            }
          }
        } catch let error as PostgresTransactionError {
          if error.rollbackError != nil {
            try? await connection.close()
          }
          throw error
        }
      }

      context.logger.debug("Committed database transaction")
      return result
    } catch {
      context.logger.debug("Database transaction did not commit")
      throw error
    }
  }

  func withMigrationLock<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    do {
      return try await self.withTransaction(context: context, isolation: isolation) { transaction in
        try await transaction.execute(
          #sql("SELECT pg_advisory_xact_lock(1448300877, 1296648018)", as: Void.self),
          logger: context.logger,
          file: context.file,
          line: context.line
        )
        return try await operation(transaction)
      }
    } catch let error as PostgresTransactionError {
      if error.beginError == nil,
        error.rollbackError == nil,
        error.commitError == nil,
        let closureError = error.closureError
      {
        throw closureError
      }
      throw error
    }
  }

  func checkReadiness(
    context: DatabaseExecutionContext,
    timeout: Duration
  ) async throws {
    let lease = try self.lifecycle.beginOperation()
    defer { lease.release() }
    do {
      try await withReadinessTimeout(timeout) {
        try await self.client.withConnection { connection in
          _ = try await connection.execute(
            #sql("SELECT 1", as: Void.self),
            logger: context.logger,
            file: context.file,
            line: context.line
          )
        }
      }
      context.logger.debug("Database readiness check succeeded")
    } catch {
      context.logger.warning("Database readiness check failed")
      throw error
    }
  }

  func shutdown() async throws {
    switch self.lifecycle.beginShutdown() {
    case .initiate:
      self.logger.debug("Draining database connections")
      await self.lifecycle.waitUntilDrained()
      self.runTask.cancel()
      await self.runTask.value
      self.lifecycle.finishShutdown()
      self.logger.debug("Database shutdown complete")
    case .awaitCompletion:
      await self.lifecycle.waitUntilShutdown()
    case .complete:
      return
    }
  }
}

private final class PostgresConnectionDatabase: Database {
  enum State: Sendable {
    case leased
    case transaction
  }

  let logger: Logger
  let migrationDialect = DatabaseMigrationDialect.postgres

  private let connection: PostgresConnection
  private let state: State
  private let validity: PostgresConnectionHandleValidity

  init(
    connection: PostgresConnection,
    logger: Logger,
    state: State,
    validity: PostgresConnectionHandleValidity
  ) {
    self.connection = connection
    self.logger = logger
    self.state = state
    self.validity = validity
  }

  func stream<S: Statement>(
    _ statement: S,
    context: DatabaseExecutionContext
  ) async throws -> DatabaseRowStream<S.QueryValue.QueryOutput>
  where
    S.QueryValue: QueryRepresentable,
    S.QueryValue.QueryOutput: Sendable
  {
    let lease = try self.validity.beginOperation()
    do {
      let stream = DatabaseRowStream(
        try await self.connection.query(
          PostgresSendableStatement<S.QueryValue>(query: statement.query),
          logger: context.logger,
          file: context.file,
          line: context.line
        )
      )
      lease.release()
      self.validity.register {
        stream.cancel()
      }
      return stream
    } catch {
      lease.release()
      throw error
    }
  }

  func execute<S: Statement>(
    _ statement: S,
    context: DatabaseExecutionContext
  ) async throws -> DatabaseCommandMetadata?
  where S.QueryValue == () {
    let lease = try self.validity.beginOperation()
    defer { lease.release() }
    return try await self.connection.execute(
      statement,
      logger: context.logger,
      file: context.file,
      line: context.line
    )
    .map(DatabaseCommandMetadata.init)
  }

  func withConnection<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    let lease = try self.validity.beginOperation()
    defer { lease.release() }
    return try await operation(self)
  }

  func withTransaction<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    let outerLease = try self.validity.beginOperation()
    defer { outerLease.release() }
    guard case .leased = self.state else {
      throw DatabaseRuntimeError.nestedTransactionUnsupported
    }

    context.logger.debug("Beginning database transaction")
    do {
      let result = try await self.connection.withTransaction(
        logger: context.logger,
        file: context.file,
        line: context.line,
        isolation: isolation
      ) { connection in
        let validity = PostgresConnectionHandleValidity()
        let database = PostgresConnectionDatabase(
          connection: connection,
          logger: context.logger,
          state: .transaction,
          validity: validity
        )
        do {
          let result = try await operation(database)
          await validity.invalidateAndWait()
          return result
        } catch {
          await validity.invalidateAndWait()
          throw error
        }
      }
      context.logger.debug("Committed database transaction")
      return result
    } catch let error as PostgresTransactionError {
      if error.rollbackError != nil {
        try? await self.connection.close()
      }
      context.logger.debug("Database transaction did not commit")
      throw error
    } catch {
      context.logger.debug("Database transaction did not commit")
      throw error
    }
  }

  func withMigrationLock<Result: Sendable>(
    context: DatabaseExecutionContext,
    isolation: isolated (any Actor)?,
    _ operation: (any Database) async throws -> sending Result
  ) async throws -> sending Result {
    let lease = try self.validity.beginOperation()
    defer { lease.release() }
    guard case .leased = self.state else {
      throw DatabaseRuntimeError.nestedTransactionUnsupported
    }
    do {
      return try await self.withTransaction(context: context, isolation: isolation) { transaction in
        try await transaction.execute(
          #sql("SELECT pg_advisory_xact_lock(1448300877, 1296648018)", as: Void.self),
          logger: context.logger,
          file: context.file,
          line: context.line
        )
        return try await operation(transaction)
      }
    } catch let error as PostgresTransactionError {
      if error.beginError == nil,
        error.rollbackError == nil,
        error.commitError == nil,
        let closureError = error.closureError
      {
        throw closureError
      }
      throw error
    }
  }

  func checkReadiness(
    context: DatabaseExecutionContext,
    timeout: Duration
  ) async throws {
    let lease = try self.validity.beginOperation()
    defer { lease.release() }
    try await withReadinessTimeout(timeout) {
      _ = try await self.connection.execute(
        #sql("SELECT 1", as: Void.self),
        logger: context.logger,
        file: context.file,
        line: context.line
      )
    }
  }

  func shutdown() async throws {
    try self.validity.check()
    throw DatabaseRuntimeError.unsupportedOperation(.shutdown)
  }
}

private final class PostgresConnectionHandleValidity: Sendable {
  private struct State: Sendable {
    var isValid = true
    var activeOperations = 0
    var invalidationHandlers: [@Sendable () -> Void] = []
    var drainContinuations: [CheckedContinuation<Void, Never>] = []
  }

  private let state = NIOLockedValueBox(State())

  func check() throws {
    guard self.state.withLockedValue({ $0.isValid }) else {
      throw DatabaseRuntimeError.borrowedConnectionExpired
    }
  }

  func beginOperation() throws -> PostgresConnectionOperationLease {
    try self.state.withLockedValue { state in
      guard state.isValid else {
        throw DatabaseRuntimeError.borrowedConnectionExpired
      }
      state.activeOperations += 1
      return PostgresConnectionOperationLease { [weak self] in
        self?.finishOperation()
      }
    }
  }

  func register(_ handler: @escaping @Sendable () -> Void) {
    let runImmediately = self.state.withLockedValue { state in
      guard state.isValid else {
        return true
      }
      state.invalidationHandlers.append(handler)
      return false
    }
    if runImmediately {
      handler()
    }
  }

  func invalidateAndWait() async {
    let handlers = self.state.withLockedValue { state -> [@Sendable () -> Void] in
      guard state.isValid else {
        return []
      }
      state.isValid = false
      return state.invalidationHandlers.takeAll()
    }
    for handler in handlers {
      handler()
    }
    await withCheckedContinuation { continuation in
      let resumeImmediately = self.state.withLockedValue { state in
        if state.activeOperations == 0 {
          return true
        }
        state.drainContinuations.append(continuation)
        return false
      }
      if resumeImmediately {
        continuation.resume()
      }
    }
  }

  private func finishOperation() {
    let continuations = self.state.withLockedValue {
      state -> [CheckedContinuation<Void, Never>] in
      precondition(state.activeOperations > 0)
      state.activeOperations -= 1
      guard !state.isValid, state.activeOperations == 0 else {
        return []
      }
      return state.drainContinuations.takeAll()
    }
    for continuation in continuations {
      continuation.resume()
    }
  }
}

private final class PostgresConnectionOperationLease: Sendable {
  private let releaseOperation: NIOLockedValueBox<(@Sendable () -> Void)?>

  init(release: @escaping @Sendable () -> Void) {
    self.releaseOperation = NIOLockedValueBox(release)
  }

  func release() {
    self.releaseOperation.withLockedValue { $0.take()?() }
  }

  deinit {
    self.release()
  }
}

extension DatabaseCommandMetadata {
  fileprivate init(_ metadata: PostgresQueryMetadata) {
    self.init(command: metadata.command, rowsAffected: metadata.rows)
  }
}

private struct PostgresSendableStatement<Value: QueryRepresentable>: Statement
where Value.QueryOutput: Sendable {
  typealias QueryValue = PostgresSendableQueryValue<Value>
  typealias From = Never

  let query: QueryFragment
}

private struct PostgresSendableQueryValue<Value: QueryRepresentable>:
  QueryRepresentable, Sendable
where Value.QueryOutput: Sendable {
  let queryOutput: Value.QueryOutput

  init(queryOutput: Value.QueryOutput) {
    self.queryOutput = queryOutput
  }

  init(decoder: inout some QueryDecoder) throws {
    self.queryOutput = try Value(decoder: &decoder).queryOutput
  }
}

private func withReadinessTimeout(
  _ timeout: Duration,
  operation: @escaping @Sendable () async throws -> Void
) async throws {
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask {
      try await operation()
    }
    group.addTask {
      try await ContinuousClock().sleep(for: timeout)
      try Task.checkCancellation()
      throw DatabaseRuntimeError.readinessTimedOut
    }
    defer { group.cancelAll() }
    guard let result = try await group.next() else {
      throw CancellationError()
    }
    return result
  }
}

private final class PostgresDatabaseLifecycle: Sendable {
  enum ShutdownAction {
    case initiate
    case awaitCompletion
    case complete
  }

  private enum Phase: Sendable {
    case running
    case draining
    case stopped
  }

  private struct State: Sendable {
    var phase = Phase.running
    var operationCount = 0
    var drainWaiters: [CheckedContinuation<Void, Never>] = []
    var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
  }

  private let state = NIOLockedValueBox(State())

  func beginOperation() throws -> PostgresDatabaseOperationLease {
    try self.state.withLockedValue { state in
      switch state.phase {
      case .running:
        state.operationCount += 1
        return PostgresDatabaseOperationLease {
          self.endOperation()
        }
      case .draining:
        throw DatabaseRuntimeError.databaseShuttingDown
      case .stopped:
        throw DatabaseRuntimeError.databaseShutdown
      }
    }
  }

  func beginShutdown() -> ShutdownAction {
    self.state.withLockedValue { state in
      switch state.phase {
      case .running:
        state.phase = .draining
        return .initiate
      case .draining:
        return .awaitCompletion
      case .stopped:
        return .complete
      }
    }
  }

  func waitUntilDrained() async {
    await withCheckedContinuation { continuation in
      let shouldResume = self.state.withLockedValue { state in
        if state.operationCount == 0 {
          return true
        }
        state.drainWaiters.append(continuation)
        return false
      }
      if shouldResume {
        continuation.resume()
      }
    }
  }

  func waitUntilShutdown() async {
    await withCheckedContinuation { continuation in
      let shouldResume = self.state.withLockedValue { state in
        if case .stopped = state.phase {
          return true
        }
        state.shutdownWaiters.append(continuation)
        return false
      }
      if shouldResume {
        continuation.resume()
      }
    }
  }

  func finishShutdown() {
    let waiters = self.state.withLockedValue { state in
      state.phase = .stopped
      return state.shutdownWaiters.takeAll()
    }
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func endOperation() {
    let waiters = self.state.withLockedValue { state -> [CheckedContinuation<Void, Never>] in
      precondition(state.operationCount > 0)
      state.operationCount -= 1
      guard state.operationCount == 0 else {
        return []
      }
      return state.drainWaiters.takeAll()
    }
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private final class PostgresDatabaseOperationLease: Sendable {
  private let operation: NIOLockedValueBox<(@Sendable () -> Void)?>

  init(_ operation: @escaping @Sendable () -> Void) {
    self.operation = NIOLockedValueBox(operation)
  }

  deinit {
    self.release()
  }

  func release() {
    self.operation.withLockedValue { $0.take() }?()
  }
}

extension Array {
  fileprivate mutating func takeAll() -> Self {
    defer { self.removeAll(keepingCapacity: false) }
    return self
  }
}

extension Optional {
  fileprivate mutating func take() -> Wrapped? {
    defer { self = nil }
    return self
  }
}
