import StructuredQueries

extension SelectStatement where QueryValue == (), Joins == (), From.QueryOutput: Sendable {
  /// Executes an implicit whole-table selection and decodes all rows.
  ///
  /// - Parameter database: The destination database.
  /// - Returns: Decoded table rows.
  /// - Throws: An error if execution or decoding fails.
  public func all(on database: any Database) async throws -> [From.QueryOutput] {
    try await database.all(SQLQueryExpression(self.selectStar().query, as: From.self))
  }

  /// Executes an implicit whole-table selection and decodes the first row, if present.
  ///
  /// - Parameter database: The destination database.
  /// - Returns: The first decoded table row, if any.
  /// - Throws: An error if execution or decoding fails.
  public func first(on database: any Database) async throws -> From.QueryOutput? {
    try await database.first(SQLQueryExpression(self.selectStar().query, as: From.self))
  }
}

extension Statement where QueryValue == () {
  /// Executes a non-returning statement on a database.
  ///
  /// - Parameter database: The destination database.
  /// - Throws: An error if execution fails.
  public func execute(on database: any Database) async throws {
    try await database.execute(self)
  }
}

extension Statement where QueryValue: QueryRepresentable, QueryValue.QueryOutput: Sendable {
  /// Executes a statement and decodes all rows.
  ///
  /// - Parameter database: The destination database.
  /// - Returns: Decoded rows.
  /// - Throws: An error if execution or decoding fails.
  public func all(on database: any Database) async throws -> [QueryValue.QueryOutput] {
    try await database.all(self)
  }

  /// Executes a statement and decodes the first row.
  ///
  /// - Parameter database: The destination database.
  /// - Returns: The first decoded row, if any.
  /// - Throws: An error if execution or decoding fails.
  public func first(on database: any Database) async throws -> QueryValue.QueryOutput? {
    try await database.first(self)
  }
}
