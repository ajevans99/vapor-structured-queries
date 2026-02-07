import Logging
import NIOCore

/// A factory for constructing configured databases.
public struct DatabaseConfigurationFactory: Sendable {
  /// Creates a concrete database for a given event loop group and logger.
  public let makeDatabase: @Sendable (any EventLoopGroup, Logger) -> any Database

  /// Creates a configuration factory.
  ///
  /// - Parameter makeDatabase: Closure used to construct concrete databases.
  public init(
    makeDatabase: @escaping @Sendable (any EventLoopGroup, Logger) -> any Database
  ) {
    self.makeDatabase = makeDatabase
  }
}
