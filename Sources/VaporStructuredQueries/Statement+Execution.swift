import Logging
import StructuredQueries

extension Statement where QueryValue == () {
  /// Executes a non-returning statement on a database.
  ///
  /// - Parameters:
  ///   - database: The destination database.
  ///   - logger: An optional operation logger.
  ///   - file: The caller's source file.
  ///   - line: The caller's source line.
  /// - Returns: Truthful command metadata when the driver provides it.
  /// - Throws: An error if execution fails.
  @discardableResult
  public func execute(
    on database: any Database,
    logger: Logger? = nil,
    file: String = #fileID,
    line: Int = #line
  ) async throws -> DatabaseCommandMetadata? {
    try await database.execute(self, logger: logger, file: file, line: line)
  }
}

extension Statement
where QueryValue: QueryRepresentable, QueryValue.QueryOutput: Sendable {
  /// Executes a statement and streams decoded rows.
  public func stream(
    on database: any Database,
    logger: Logger? = nil,
    file: String = #fileID,
    line: Int = #line
  ) async throws -> DatabaseRowStream<QueryValue.QueryOutput> {
    try await database.stream(self, logger: logger, file: file, line: line)
  }

  /// Executes a statement and decodes all rows.
  ///
  /// - Parameters:
  ///   - database: The destination database.
  ///   - logger: An optional operation logger.
  ///   - file: The caller's source file.
  ///   - line: The caller's source line.
  /// - Returns: Decoded rows.
  /// - Throws: An error if execution or decoding fails.
  public func all(
    on database: any Database,
    logger: Logger? = nil,
    file: String = #fileID,
    line: Int = #line
  ) async throws -> [QueryValue.QueryOutput] {
    try await database.all(self, logger: logger, file: file, line: line)
  }

  /// Executes a statement and decodes the first row.
  ///
  /// - Parameters:
  ///   - database: The destination database.
  ///   - logger: An optional operation logger.
  ///   - file: The caller's source file.
  ///   - line: The caller's source line.
  /// - Returns: The first decoded row, if any.
  /// - Throws: An error if execution or decoding fails.
  public func first(
    on database: any Database,
    logger: Logger? = nil,
    file: String = #fileID,
    line: Int = #line
  ) async throws -> QueryValue.QueryOutput? {
    try await database.first(self, logger: logger, file: file, line: line)
  }
}
