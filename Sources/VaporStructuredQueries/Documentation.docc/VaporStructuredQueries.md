# ``VaporStructuredQueries``

Server-side integration between Vapor and StructuredQueries.

## Overview

`VaporStructuredQueries` provides:

- Database registration and lookup via `app.database`
- Request-level access via `req.db`
- Typed statement execution helpers (`execute(on:)`, `first(on:)`, `all(on:)`)
- Async migration registration and execution
- A `migrate` command and lifecycle-driven auto-migrate/auto-revert flags

Use a driver module such as `VaporStructuredQueriesPostgresNIO` to configure concrete databases.

## Topics

### Database Runtime

- ``Database``
- ``DatabaseID``
- ``Databases``
- ``DatabaseConfigurationFactory``

### Migrations

- ``AsyncMigration``
- ``Migrations``
- ``Migrator``
- ``MigrateCommand``
