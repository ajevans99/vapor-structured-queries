import Vapor

/// A command that prepares or reverts migrations.
public final class MigrateCommand: AsyncCommand {
  /// Command-line options for migrate command.
  public struct Signature: CommandSignature {
    /// Reverts all migrations when set.
    @Flag(name: "revert")
    public var revert: Bool

    /// Creates an empty signature.
    public init() {}
  }

  /// The command signature.
  public let signature = Signature()

  /// Help text displayed in command listings.
  public var help: String {
    "Prepare or revert your database migrations"
  }

  /// Creates a migrate command.
  public init() {}

  /// Runs the migrate command.
  ///
  /// - Parameters:
  ///   - context: The command context.
  ///   - signature: Parsed command signature.
  /// - Throws: An error if migration execution fails.
  public func run(using context: CommandContext, signature: Signature) async throws {
    if signature.revert {
      context.console.info("Migrate Command: Revert")
      try await context.application.autoRevert()
      context.console.info("Revert successful")
    } else {
      context.console.info("Migrate Command: Prepare")
      try await context.application.autoMigrate()
      context.console.info("Migration successful")
    }
  }
}
