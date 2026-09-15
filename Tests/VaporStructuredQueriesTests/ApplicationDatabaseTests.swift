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
        _ = try await #sql("SELECT 1", as: Int.self).all(on: app.structuredQueriesDB)
        #expect(Bool(false))
      } catch let error as Abort {
        #expect(error.status == .internalServerError)
      }
    }
  }

  @Test("prefixed application and request database accessors resolve the configured database")
  func prefixedAccessors() async throws {
    try await withApp { app in
      let database = FakeDatabase()
      database.queueFirst(42, forSQL: "SELECT 42")
      app.database.use(.init { _, _ in database }, as: "test")
      app.database.default(to: "test")
      let request = Request(application: app, on: app.eventLoopGroup.next())
      let resolved: [any VaporStructuredQueries.Database] = [
        app.structuredQueriesDB,
        app.structuredQueriesDB("test"),
        app.structuredQueriesDB("test", logger: app.logger),
        request.structuredQueriesDB,
        request.structuredQueriesDB("test"),
        request.structuredQueriesDB("test", logger: request.logger),
      ]
      for db in resolved {
        let value = try await #sql("SELECT 42", as: Int.self).first(on: db)
        #expect(value == 42)
      }
      #expect(app.structuredQueriesDatabases === app.database.storage.databases)
      #expect(app.structuredQueriesMigrations === app.database.storage.migrations)
    }
  }

  #if !FluentCompatibility
    @Test("standalone aliases remain available by default")
    func standaloneAliases() async throws {
      try await withApp { app in
        let database = FakeDatabase()
        database.queueFirst(42, forSQL: "SELECT 42")
        app.database.use(.init { _, _ in database }, as: "test")
        app.database.default(to: "test")
        let request = Request(application: app, on: app.eventLoopGroup.next())
        let resolved: [any VaporStructuredQueries.Database] = [
          app.db, app.db("test"), app.db("test", logger: app.logger),
          request.db, request.db("test"), request.db("test", logger: request.logger),
        ]
        for db in resolved {
          let value = try await #sql("SELECT 42", as: Int.self).first(on: db)
          #expect(value == 42)
        }
        #expect(app.databases === app.structuredQueriesDatabases)
        #expect(app.migrations === app.structuredQueriesMigrations)
        _ = app.migrator
        try await app.autoMigrate()
        try await app.autoRevert()
      }
    }
  #endif
}
