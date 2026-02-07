import StructuredQueries
import Testing
import VaporStructuredQueries
import VaporStructuredQueriesTestSupport

struct StatementExecutionTests {
  @Test("execute(on:) forwards to database")
  func executeForwards() async throws {
    let database = FakeDatabase()

    try await #sql("SELECT \(bind: 1)", as: Void.self)
      .execute(on: database)

    let statements = database.recordedStatements()
    #expect(statements.count == 1)
    #expect(statements[0].sql == "SELECT ?")
    #expect(statements[0].bindCount == 1)
  }

  @Test("all(on:) decodes queued rows")
  func allForwards() async throws {
    let database = FakeDatabase()
    database.queueAll([1, 2, 3], forSQL: "SELECT ?")

    let rows = try await #sql("SELECT \(bind: 1)", as: Int.self)
      .all(on: database)

    #expect(rows == [1, 2, 3])
  }

  @Test("first(on:) decodes queued row")
  func firstForwards() async throws {
    let database = FakeDatabase()
    database.queueFirst(42, forSQL: "SELECT ?")

    let row = try await #sql("SELECT \(bind: 1)", as: Int.self)
      .first(on: database)

    #expect(row == 42)
  }
}
