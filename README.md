# Vapor Structured Queries

[![CI](https://github.com/ajevans99/vapor-structured-queries/actions/workflows/ci.yml/badge.svg)](https://github.com/ajevans99/vapor-structured-queries/actions/workflows/ci.yml)

Vapor integration for [swift-structured-queries](https://github.com/pointfreeco/swift-structured-queries).

## Why this exists

This package gives Vapor apps a Fluent-like runtime surface (`app.database`, `req.db`, migrations, lifecycle hooks), but keeps query authoring firmly in [swift-structured-queries](https://github.com/pointfreeco/swift-structured-queries).

- This is not an ORM.
- There is no model lifecycle/state tracking.
- Queries are explicit SQL builders (or safe `#sql`) with strong type/schema safety.

If you know [FluentKit](https://github.com/vapor/fluent-kit), the API style here is intentionally familiar for app wiring and migrations, while query composition follows StructuredQueries semantics.

## Modules

- `VaporStructuredQueries`: core runtime, Vapor wiring, migrations, statement execution helpers.
- `VaporStructuredQueriesPostgresNIO`: Postgres driver implementation.
- `VaporStructuredQueriesSQLite`: SQLite driver implementation using StructuredQueries' SQLite driver.
- `VaporStructuredQueriesTestSupport`: fake database utilities for unit tests.

## Compatibility

Requires Swift 6.1 or newer and macOS 13 or newer. StructuredQueries is pinned to
[`ajevans99/swift-structured-queries` at `181cf5ec`](https://github.com/ajevans99/swift-structured-queries/commit/181cf5ece309934ab85340e546777af3ddf8bb06),
which incorporates upstream `a834ac78` while retaining the `StructuredQueriesPostgresNIO` product.
The upstream-only package does not provide this bridge. Swift 6.4 uses the dependency's main
manifest; Swift 6.1-6.3 uses its compatibility manifest. Both use the
`xctest-dynamic-overlay` dependency identity and support CasePaths 1.8 to remain compatible with
existing package graphs.

### Coexisting with Fluent

Enable the opt-in `FluentCompatibility` SwiftPM trait when importing both integrations:

```swift
.package(
  url: "https://github.com/ajevans99/vapor-structured-queries.git",
  branch: "main",
  traits: ["FluentCompatibility"]
)
```

This removes only this package's conveniences that overlap Fluent: `Application.db`, `Request.db`
(including identifier/logger overloads), and `Application.databases`, `migrations`, `migrator`,
`autoMigrate()`, and `autoRevert()`. Existing standalone names remain available by default.
The following unambiguous equivalents are available with or without the trait:

| Standalone convenience | Always-available StructuredQueries name |
| --- | --- |
| `app.db` / `req.db` and `db(...)` | `app.structuredQueriesDB` / `req.structuredQueriesDB` and `structuredQueriesDB(...)` |
| `app.databases` | `app.structuredQueriesDatabases` |
| `app.migrations` | `app.structuredQueriesMigrations` |
| `app.migrator` | `app.structuredQueriesMigrator` |
| `app.autoMigrate()` | `app.structuredQueriesAutoMigrate()` |
| `app.autoRevert()` | `app.structuredQueriesAutoRevert()` |

The `app.database` configuration namespace and `connection.structuredQueries(logger:)` borrowed
adapter are unchanged. The trait adds no Fluent dependency and does not share pools or transaction
ownership: use the borrowed adapter on Fluent's existing transaction connection when affinity matters.
Traits are package-wide, so enabling this trait affects every consumer of this package in the graph.
When using a project generator, ensure it propagates the selected trait to the package's compilation
conditions. To verify locally, run `swift test --traits FluentCompatibility`.

## Quick start

```swift
import Vapor
import VaporStructuredQueries
import VaporStructuredQueriesPostgresNIO

func configure(_ app: Application) async throws {
  app.database.use(
    .postgres(
      hostname: "localhost",
      username: "vapor_username",
      password: "vapor_password",
      database: "vapor_database"
    ),
    as: .psql
  )
  app.database.default(to: .psql)
}
```

In handlers, execute statements on `req.db`:

```swift
let rows = try await #sql("SELECT \(bind: 1)", as: Int.self).all(on: req.db)
```

### Borrowing an existing Postgres connection

When a connection is already leased (for example, by a transaction owner), use
`connection.structuredQueries(logger:)` instead of configuring a second pool:

```swift
import StructuredQueries
import StructuredQueriesPostgresNIO
import VaporStructuredQueries
import VaporStructuredQueriesPostgresNIO

try await client.withConnection { connection in
  let database = connection.structuredQueries(logger: logger)
  let rows = try await #sql("SELECT \(bind: 1)", as: Int.self).all(on: database)
}
```

Every operation uses that exact connection and sees its current transaction. For a Fluent-owned
transaction, pass the connection belonging to that transaction, not a new lease from another pool.
Keep the adapter and all operations inside the owner's connection/transaction scope; the adapter does
not extend the lease and must not be cached in `app.databases`. The owner controls commit/rollback.
`shutdown()` does nothing and never closes the borrowed connection during ordinary cleanup.
Cancellation still uses the native bridge's behavior: cancelling a non-returning `execute` can close
the connection, so the owner must handle transaction and connection cleanup on cancellation.

SQLite example:

```swift
import VaporStructuredQueriesSQLite

func configureSQLite(_ app: Application) async throws {
  app.database.use(.sqlite(path: "/tmp/app.sqlite"), as: .sqlite)
  app.database.default(to: .sqlite)
}
```

## Builder-style StructuredQueries examples

```swift
import StructuredQueries

@Table
struct Todo {
  let id: UUID
  var title = ""
  var isComplete = false
}
```

Select:

```swift
let openTodos = try await Todo
  .where { !$0.isComplete }
  .order(by: \.title)
  .all(on: req.db)
```

Project custom selections:

```swift
let titles = try await Todo
  .select(\.title)
  .where { !$0.isComplete }
  .all(on: req.db)
```

Insert using generated `Draft` type:

```swift
try await Todo.insert {
  Todo.Draft(id: UUID(), title: "Wash the car", isComplete: false)
}
.execute(on: req.db)
```

Use explicit bindings when assigning runtime values in an update:

```swift
let newTitle = "Wash the car tomorrow"
try await Todo.where { !$0.isComplete }.update {
  $0.title = #bind(newTitle)
}
.execute(on: req.db)
```

You can still mix in raw SQL safely with `#sql` when needed.

## Draft features

The `@Table` macro generates a strongly typed `Draft` model for writes, enabling ergonomic insert/upsert flows with compile-time column validation. For deeper details, see StructuredQueries docs:

- [Defining your schema](https://swiftpackageindex.com/pointfreeco/swift-structured-queries/~/documentation/structuredqueriescore/definingyourschema)
- [Primary-keyed tables](https://swiftpackageindex.com/pointfreeco/swift-structured-queries/~/documentation/structuredqueriescore/primarykeyedtables)
- [Insert statements](https://swiftpackageindex.com/pointfreeco/swift-structured-queries/~/documentation/structuredqueriescore/insertstatements)

## Migrations

Register `AsyncMigration` values on `app.migrations`, then run:

```bash
swift run <YourApp> migrate
swift run <YourApp> migrate --revert
```

Or use lifecycle flags:

```bash
swift run <YourApp> --auto-migrate
swift run <YourApp> --auto-revert
```

Example migration:

```swift
import StructuredQueries
import VaporStructuredQueries

struct CreateTodos: AsyncMigration {
  func prepare(on database: any Database) async throws {
    try await #sql(
      """
      CREATE TABLE IF NOT EXISTS \(raw: "todos") (
        \(raw: "id") UUID PRIMARY KEY,
        \(raw: "title") TEXT NOT NULL,
        \(raw: "is_complete") BOOLEAN NOT NULL
      )
      """
    )
    .execute(on: database)
  }

  func revert(on database: any Database) async throws {
    try await #sql("DROP TABLE IF EXISTS \(raw: "todos")").execute(on: database)
  }
}
```

## StructuredQueries resources

- [StructuredQueries repository](https://github.com/pointfreeco/swift-structured-queries)
- [StructuredQueries docs](https://swiftpackageindex.com/pointfreeco/swift-structured-queries/~/documentation/structuredqueriescore/)
- [Safe SQL strings](https://swiftpackageindex.com/pointfreeco/swift-structured-queries/~/documentation/structuredqueriescore/safesqlstrings)
- [Query cookbook](https://swiftpackageindex.com/pointfreeco/swift-structured-queries/~/documentation/structuredqueriescore/querycookbook)

## Development

- `make format`
- `make lint`
- `swift build`
- `swift test`

Postgres integration tests are explicitly skipped unless enabled. Run them against a **dedicated,
disposable database** (not an application database, and not shared by concurrent test runs):

```bash
RUN_POSTGRES_INTEGRATION_TESTS=1 \
POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=5432 \
POSTGRES_USER=postgres POSTGRES_DB=vsq_test \
swift test
```

Set `POSTGRES_PASSWORD` through the environment when authentication requires it. Once enabled, missing
connection settings, invalid ports, and connection failures fail the tests rather than silently
skipping them. Tests cover raw SQL and typed insert/select/update/delete statements, `RETURNING`,
nullable values, native Boolean/UUID/Date/blob round trips, and query/decoding errors on both backends. Test tables
are dropped after the flow, including on failure. Postgres uses regular tables because consecutive
operations on the pooled client do not guarantee the same connection.

## License

MIT. See `LICENSE`.
