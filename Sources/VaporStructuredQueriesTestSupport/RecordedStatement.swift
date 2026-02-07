import StructuredQueries

/// A normalized SQL statement captured by test support.
public struct RecordedStatement: Equatable, Sendable {
  /// The prepared SQL string.
  public let sql: String

  /// The number of bound parameters in the statement.
  public let bindCount: Int

  /// Creates a recorded statement from a query fragment.
  ///
  /// - Parameter query: The query fragment to prepare.
  public init(query: QueryFragment) {
    let prepared = query.prepare { _ in "?" }
    self.sql = prepared.sql
    self.bindCount = prepared.bindings.count
  }
}
