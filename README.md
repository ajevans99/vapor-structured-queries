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

## License

MIT. See `LICENSE`.
