# ``VaporStructuredQueries``

Server-side integration between Vapor and StructuredQueries.

## Overview

`VaporStructuredQueries` provides:

- Database registration and lookup via `app.database`
- Request-level access via `req.db`
- Typed statement execution helpers (`execute(on:)`, `first(on:)`, `all(on:)`)
- Transactional, cross-process-safe Postgres migration execution
- Latest-batch and explicit all-batches revert commands

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
- ``MigrationError``
- ``AppliedMigrationRecord``

Postgres migration commands hold the stable advisory lock
`(1448300877, 1296648018)` and one transaction across tracking-table evolution,
history validation, migration bodies, and bookkeeping. Apply order is
registration order; revert order is the exact reverse persisted `sequence`.
Unknown applied migration names fail without deleting tracking records.

SQLite migration commands hold an in-process gate and a same-connection
`BEGIN IMMEDIATE` transaction. File databases retry busy/locked acquisition so
independent connections serialize; `:memory:` guarantees only same-instance
serialization. Legacy SQLite tables are rebuilt and copied transactionally to
enforce the non-null unique sequence.

Legacy equal-batch order is inferred from current registration order and emits
a warning. It cannot detect already-applied known migrations that were
reordered. Postgres migration bodies must be transaction-compatible;
`CREATE INDEX CONCURRENTLY` and similar non-transactional DDL are unsupported.

Third-party drivers must provide a truthful ``Database/migrationDialect`` and
``Database/withMigrationLock(context:isolation:_:)`` implementation or they
fail closed.

Use `migrate --revert` for the latest batch and reserve the explicitly
destructive `migrate --revert-all` for intentional full rollback. Prefer a
deployment-controlled migration job over boot-time migration in production.
