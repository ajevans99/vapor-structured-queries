/// A stable identifier for a configured database.
public struct DatabaseID: Hashable, Codable, Sendable, ExpressibleByStringLiteral {
  /// The string representation of the database identifier.
  public var string: String

  /// Creates a database identifier from a raw string.
  ///
  /// - Parameter string: The identifier value.
  public init(string: String) {
    self.string = string
  }

  /// Creates a database identifier from a string literal.
  ///
  /// - Parameter value: The identifier value.
  public init(stringLiteral value: String) {
    self.init(string: value)
  }
}
