import StructuredQueries

/// A runtime database capable of executing StructuredQueries statements.
public protocol Database: Sendable {
  /// Executes a statement and decodes all rows.
  ///
  /// - Parameter statement: The statement to execute.
  /// - Returns: The decoded rows.
  /// - Throws: An error if execution or decoding fails.
  func all<S: Statement>(_ statement: S) async throws -> [S.QueryValue.QueryOutput]
  where S.QueryValue: QueryRepresentable, S.QueryValue.QueryOutput: Sendable

  /// Executes a statement and decodes the first row.
  ///
  /// - Parameter statement: The statement to execute.
  /// - Returns: The first decoded row, if any.
  /// - Throws: An error if execution or decoding fails.
  func first<S: Statement>(_ statement: S) async throws -> S.QueryValue.QueryOutput?
  where S.QueryValue: QueryRepresentable, S.QueryValue.QueryOutput: Sendable

  /// Executes a statement that does not return row data.
  ///
  /// - Parameter statement: The statement to execute.
  /// - Throws: An error if execution fails.
  func execute(_ statement: some Statement<()>) async throws

  /// Shuts down any resources held by this database.
  func shutdown()
}
