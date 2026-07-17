import Logging
import StructuredQueries
import Testing
import Vapor
import VaporStructuredQueriesTestSupport
import VaporTesting

@testable import VaporStructuredQueries

struct ApplicationDatabaseTests {
  @Test("database namespace registers migrate command")
  func migrateCommandRegistered() async throws {
    try await withApp { app in
      _ = app.database
      #expect(app.asyncCommands.commands["migrate"] != nil)
    }
  }

  @Test("unconfigured database throws internal server error")
  func unconfiguredDatabase() async throws {
    try await withApp { app in
      do {
        _ = try await #sql("SELECT 1", as: Int.self).all(on: app.db)
        #expect(Bool(false))
      } catch let error as Abort {
        #expect(error.status == .internalServerError)
      }
    }
  }

  @Test("database lookups preserve operation logger context")
  func contextualLogger() async throws {
    let database = FakeDatabase()
    try await withApp { app in
      try await app.database.use(.init { _, _ in database }, as: "test")
      app.database.default(to: "test")

      _ = app.db
      _ = try await #sql("SELECT 1", as: Void.self).execute(
        on: app.db(nil, logger: Logger(label: "request-logger")),
        file: "RequestRoute.swift",
        line: 27
      )
    }

    #expect(database.recordedContexts().first?.loggerLabel == "request-logger")
    #expect(database.recordedContexts().first?.file == "RequestRoute.swift")
    #expect(database.recordedContexts().first?.line == 27)
  }

  @Test("replacing a materialized database awaits shutdown")
  func replacementShutdown() async throws {
    let first = FakeDatabase()
    let second = FakeDatabase()

    try await withApp { app in
      try await app.database.use(.init { _, _ in first }, as: "test")
      app.database.default(to: "test")
      _ = app.db

      try await app.database.use(.init { _, _ in second }, as: "test")
      try await second.checkReadiness()

      await #expect(throws: DatabaseRuntimeError.databaseShutdown) {
        try await first.checkReadiness()
      }
    }
  }

  @Test("registry shutdown is concurrently idempotent")
  func concurrentShutdown() async throws {
    let database = FakeDatabase()

    try await withApp { app in
      try await app.database.use(.init { _, _ in database }, as: "test")
      app.database.default(to: "test")
      _ = app.db

      async let first: Void = app.databases.shutdown()
      async let second: Void = app.databases.shutdown()
      _ = try await (first, second)
      #expect(database.shutdownCallCount() == 1)

      await #expect(throws: DatabaseRuntimeError.databaseShutdown) {
        try await database.checkReadiness()
      }
    }
  }

  @Test("registry shutdown clears instances and preserves its first error")
  func shutdownFailure() async throws {
    let failing = FakeDatabase()
    let successful = FakeDatabase()
    failing.setShutdownError(ShutdownFailure())

    try await withApp { app in
      let databases = Databases(on: app.eventLoopGroup, logger: app.logger)
      try await databases.use(.init { _, _ in failing }, as: "failing")
      try await databases.use(.init { _, _ in successful }, as: "successful")
      _ = databases.database("failing", logger: app.logger)
      _ = databases.database("successful", logger: app.logger)

      await #expect(throws: ShutdownFailure.self) {
        try await databases.shutdown()
      }
      await #expect(throws: ShutdownFailure.self) {
        try await databases.shutdown()
      }

      #expect(failing.shutdownCallCount() == 1)
      #expect(successful.shutdownCallCount() == 1)
    }
  }
}

private struct ShutdownFailure: Error {}
