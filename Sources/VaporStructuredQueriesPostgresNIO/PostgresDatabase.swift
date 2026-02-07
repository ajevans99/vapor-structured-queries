import Logging
import NIOCore
import StructuredQueriesPostgresNIO
import VaporStructuredQueries

final class PostgresDatabase: Database {
  private let client: PostgresClient
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
    self.runTask = Task {
      await client.run()
    }
  }

  deinit {
    self.runTask.cancel()
  }

  func all<S: Statement>(_ statement: S) async throws -> [S.QueryValue.QueryOutput]
  where S.QueryValue: QueryRepresentable, S.QueryValue.QueryOutput: Sendable {
    var results: [S.QueryValue.QueryOutput] = []
    for try await row in try self.client.query(statement) {
      results.append(row)
    }
    return results
  }

  func first<S: Statement>(_ statement: S) async throws -> S.QueryValue.QueryOutput?
  where S.QueryValue: QueryRepresentable, S.QueryValue.QueryOutput: Sendable {
    for try await row in try self.client.query(statement) {
      return row
    }
    return nil
  }

  func execute(_ statement: some Statement<()>) async throws {
    for try await _ in try self.client.query(statement) {
    }
  }

  func shutdown() {
    self.runTask.cancel()
  }
}
