import VaporStructuredQueries

extension DatabaseConfigurationFactory {
  /// Creates a SQLite-backed database configuration factory.
  ///
  /// - Parameter path: Path to the SQLite file. Use `:memory:` for in-memory DB.
  /// - Returns: A database configuration factory.
  public static func sqlite(path: String = ":memory:") -> Self {
    .init { _, _ in
      SQLiteDatabase(path: path)
    }
  }
}
