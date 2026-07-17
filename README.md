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

## Quick start

```swift
import Vapor
import VaporStructuredQueries
import VaporStructuredQueriesPostgresNIO

func configure(_ app: Application) async throws {
  try await app.database.use(
    try .postgres(
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

The production convenience requires TLS with certificate verification. Inject
credentials from your deployment environment rather than placing them in source.
For a local Postgres server without TLS, opt in explicitly:

```swift
try await app.database.use(
  try .postgresInsecureForLocalDevelopment(
    username: "vapor_username",
    password: "vapor_password",
    database: "vapor_database"
  ),
  as: .psql
)
```

For pool and connection controls, pass `PostgresClient.Configuration.Options`:

```swift
var options = PostgresClient.Configuration.Options()
options.connectTimeout = .seconds(5)
options.minimumConnections = 2
options.maximumConnections = 20
options.connectionIdleTimeout = .seconds(60)

try await app.database.use(
  try .postgres(
    hostname: "db.internal",
    username: databaseUser,
    password: databasePassword,
    database: databaseName,
    options: options
  ),
  as: .psql
)
```

Use `.postgres(configuration:)` when the complete `PostgresClient.Configuration`
surface is required. Invalid convenience values and pool bounds throw without
including credential values in errors.

In handlers, execute statements on `req.db`:

```swift
let rows = try await #sql("SELECT \(bind: 1)", as: Int.self).all(on: req.db)
```

`req.db` carries `req.logger`, including request metadata. `app.db` uses the
application logger. Each operation also forwards its caller `#fileID` and `#line`
to Postgres for useful error locations. SQL text, binds, connection URLs, and
credentials are not logged by this package.

SQLite example:

```swift
import VaporStructuredQueriesSQLite

func configureSQLite(_ app: Application) async throws {
  try await app.database.use(.sqlite(path: "/tmp/app.sqlite"), as: .sqlite)
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

Non-returning statements return truthful portable metadata when the driver
provides it:

```swift
let metadata = try await Todo
  .where { $0.id.eq(todoID) }
  .delete()
  .execute(on: req.db)

if let rowsAffected = metadata?.rowsAffected {
  req.logger.debug("Deleted todos", metadata: ["rowsAffected": "\(rowsAffected)"])
}
```

An unavailable row count remains `nil`; the runtime does not infer or fabricate
one.

Stream large results with backpressure:

```swift
let todos = try await Todo
  .order(by: \.title)
  .stream(on: req.db)

for try await todo in todos {
  // Process one row at a time.
}
```

Streams are single-pass. Ending iteration, cancellation, or decode failure
releases the pooled connection.

## Transactions and leased connections

Use the same typed query operations on the transaction-bound database:

```swift
let todo = try await req.db.withTransaction { transaction in
  let todo = Todo(id: UUID(), title: "Ship it")
  try await Todo.insert { todo }.execute(on: transaction)
  return todo
}
```

The closure runs on one `PostgresConnection`, commits on success, and rolls back
on error. Its result must be `Sendable`, and caller actor isolation is preserved.
`withConnection` leases one connection without starting a transaction:

```swift
let backendPID = try await req.db.withConnection { connection in
  try await #sql("SELECT pg_backend_pid()", as: Int.self).first(on: connection)
}
```

Calling `withConnection` again on a bound handle reuses the same connection.
Calling `withTransaction` on a leased handle starts the transaction there.
Nested transactions throw `DatabaseRuntimeError.nestedTransactionUnsupported`;
savepoints are not implied.

SQLite and `FakeDatabase` explicitly report connection and transaction APIs as
unsupported rather than silently executing non-atomically.

## Readiness and lifecycle

Readiness proves pool acquisition and a lightweight query within a bound:

```swift
app.get("health", "ready") { req async throws -> HTTPStatus in
  try await req.db.checkReadiness(timeout: .seconds(2))
  return .ok
}
```

Timeout throws `DatabaseRuntimeError.readinessTimedOut`; request cancellation
remains `CancellationError`. Errors and readiness logs do not include
credentials.

Use Vapor's async application lifecycle (`Application.make` and
`app.asyncShutdown()`). The registered lifecycle handler stops new database
admissions, waits for active queries, streams, leases, and transactions, then
closes and awaits the Postgres client. Shutdown is idempotent and intentionally
has no force/deadline mode that could silently interrupt work.

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

The runtime transaction and leased-connection hooks are intended for migration
hardening: migration bodies and bookkeeping can share `withTransaction`, while a
Postgres advisory lock can use `withConnection`. This release does not yet
change migration ordering, bookkeeping, revert semantics, or advisory-lock
policy.

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

Postgres integration tests are mandatory. Set `POSTGRES_HOST`, `POSTGRES_PORT`,
`POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB`; missing configuration is
a test failure. CI provisions a real Postgres server on Linux and macOS.

## License

MIT. See `LICENSE`.
