import VaporStructuredQueries

extension DatabaseConfigurationFactory {
  /// Creates a SQLite-backed database configuration factory.
  ///
  /// File-backed migrations serialize across independent connections with
  /// `BEGIN IMMEDIATE`. In-memory migrations serialize only within one database
  /// instance because separate `:memory:` connections are separate databases.
  ///
  /// - Parameter path: Path to the SQLite file. Use `:memory:` for in-memory DB.
  /// - Returns: A database configuration factory.
  public static func sqlite(path: String = ":memory:") -> Self {
    .init { _, logger in
      SQLiteDatabase(path: path, logger: logger)
    }
  }
}
