import Vapor

/// A command that prepares or reverts migrations.
public final class MigrateCommand: AsyncCommand {
  /// Command-line options for migrate command.
  public struct Signature: CommandSignature {
    /// Reverts the latest migration batch when set.
    @Flag(name: "revert", help: "Revert only the latest applied migration batch")
    public var revert: Bool

    /// Reverts every migration batch when set.
    @Flag(name: "revert-all", help: "Destructively revert every applied migration batch")
    public var revertAll: Bool

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
    guard !(signature.revert && signature.revertAll) else {
      throw MigrationError.conflictingCommandOptions
    }
    if signature.revertAll {
      context.console.info("Migrate Command: Revert All Batches")
      try await context.application.revertAllMigrationBatches()
      context.console.info("All migration batches reverted successfully")
    } else if signature.revert {
      context.console.info("Migrate Command: Revert Latest Batch")
      try await context.application.autoRevert()
      context.console.info("Latest migration batch reverted successfully")
    } else {
      context.console.info("Migrate Command: Prepare")
      try await context.application.autoMigrate()
      context.console.info("Migration successful")
    }
  }
}
