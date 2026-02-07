import StructuredQueries
import Testing
import Vapor
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
}
