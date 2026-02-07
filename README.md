# vapor-structured-queries

Vapor integration for [StructuredQueries](https://github.com/pointfreeco/swift-structured-queries).

## Modules

- `VaporStructuredQueries`: core runtime, Vapor wiring, migrations, statement execution helpers.
- `VaporStructuredQueriesPostgresNIO`: Postgres driver implementation.
- `VaporStructuredQueriesTestSupport`: fake database utilities for unit tests.

## Quick Start

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

Execute StructuredQueries statements directly:

```swift
import StructuredQueries

let rows = try await #sql("SELECT \(bind: 1)", as: Int.self).all(on: req.db)
```

## Migrations

Register migrations on `app.migrations` and run:

```bash
swift run <YourApp> migrate
swift run <YourApp> migrate --revert
```

Or use lifecycle flags:

```bash
swift run <YourApp> --auto-migrate
swift run <YourApp> --auto-revert
```

## Development

- `make format`
- `make lint`
- `swift build`
- `swift test`

## License

MIT. See `LICENSE`.
