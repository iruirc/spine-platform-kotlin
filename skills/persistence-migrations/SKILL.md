---
name: persistence-migrations
description: "Use when designing or shipping a schema migration in a Kotlin project — Room Migration and AutoMigration with exported schemas, SQLDelight .sqm files, Flyway and Liquibase on the server, expand/contract for zero-downtime deploys, progressive chains, fixture-based migration tests. Engine-neutral discipline plus per-engine mechanics."
---

# Persistence Migrations

Changing a schema that has already shipped — on a device you cannot reach, or on a database that
must keep serving traffic while the deploy rolls. The discipline below is the same for all four
engines; the mechanics are not, and neither is the failure mode: a client migration that goes wrong
loses a user's data, and a server one takes the service down. Choosing the engine is
`persistence-room-sqldelight` and `persistence-jvm-orm`; changing what it holds is here.

> **Related skills:**
> - `persistence-architecture` — the boundary the schema hides behind, and the source-of-truth policy a migration must not silently break
> - `persistence-room-sqldelight` — the client database whose schema this skill changes, and the export setting that has to be on from version 1
> - `persistence-jvm-orm` — the server engine that validates against the schema these migrations produce
> - `release-ops` — versioning, the CI lane a migration test belongs in, and the kill switch a bad release needs
> - `release-ops-android` — the staged rollout a client migration ships behind, and why an app update cannot be rolled back
> - `release-ops-server` — migrations on deploy, readiness probes, and the blue-green or canary rollout the expand/contract steps ride on

## When to Use

- A column, a table, a type or a constraint has to change and the previous version is already
  released
- User asks "how do I add a column without downtime", "Room says it cannot verify the schema",
  "what is a `.sqm` file", "Flyway or Liquibase", "why did the deploy fail with a checksum mismatch"
- Review finds `fallbackToDestructiveMigration()`, `exportSchema = false`, an edited migration
  script, `ddl-auto=update`, or a rename in a single deploy
- A release is about to ship the first schema change since launch, and nobody has a migration test
- The symptom is `IllegalStateException: Migration didn't properly handle`, a Flyway
  `Validate failed: Migration checksum mismatch`, or a backfill that locked a table in production

Not for choosing the database (`persistence-room-sqldelight`, `persistence-jvm-orm`), not for the
repository boundary above it (`persistence-architecture`), and not for the deploy pipeline the
server steps run inside (`release-ops-server`).

## When To Load The Reference

`references/detailed-guide.md` carries the mechanics per engine — Room's exported schemas, a hand
migration, an `AutoMigration` with a rename spec and a `MigrationTestHelper` test; SQLDelight's
`.sqm` numbering and verification task; Flyway's scripts and Liquibase's changelog; then one
expand/contract change walked across four deploys and a chain test from an old dump. Every section
is self-contained; load a section, not the file:
`rg -n "^## " skills/persistence-migrations/references/detailed-guide.md`.

| Need | Reference sections |
|---|---|
| Turn on Room's schema export and commit the JSON | `Room — Exported Schemas` |
| Write a `Migration(1, 2)` by hand | `Room — A Hand-Written Migration` |
| Rename or drop a column without writing SQL | `Room — AutoMigration and Specs` |
| Test a Room migration against an old fixture | `Room — MigrationTestHelper` |
| Number, write and verify a `.sqm` file | `SQLDelight — .sqm Files and Verification` |
| Name, wire and repair Flyway scripts | `Flyway — Scripts and Wiring` |
| Write a changelog with preconditions and rollback | `Liquibase — Changelog and Changesets` |
| Rename a column with no downtime | `Expand and Contract Across Four Deploys` |
| Replay the whole chain against a production dump | `Server — Chain Test From an Old Dump` |

## Discipline

Migration rules for every framework:

1. Schema versions are checked into git.
2. Never edit a shipped schema in place.
3. Never edit a shipped migration; corrections are new migrations.
4. Use adjacent migration pairs/chains. Do not rely on one v1 -> current mega
   mapping.
5. Add fixture tests for every shipped migration.
6. Back up before heavyweight or chained migrations.
7. Surface typed migration failures to UI.
8. Emit telemetry for success/failure, duration, source/destination versions,
   and relevant system state.
9. Run migration on the foreground launch path. Defer background launches.

Two of them read differently on a server, where there is no UI and no launch. **Rule 7** becomes a
failed deploy: the migration step exits non-zero, the new version never becomes ready, and the
readiness probe keeps traffic on the old pods — a typed failure surfaced to the operator instead of
to a user. **Rule 9** becomes ordering: the migration runs to completion before the application
accepts its first request, so no code ever reads a schema that is halfway migrated.

## Room

```kotlin
@Database(entities = [OrderEntity::class], version = 2, exportSchema = true)
abstract class AppDatabase : RoomDatabase()
```

```kotlin
// build.gradle.kts — the androidx.room Gradle plugin
room { schemaDirectory("$projectDir/schemas") }
```

1. **`exportSchema = true` and a configured `schemaDirectory`, from version 1.** The plugin writes
   `<version>.json` per database; those files are committed. An auto-migration is *computed* from
   the two JSON files, and a migration test *reads* them — the schema for a version you did not
   export cannot be reconstructed once that version is on users' devices.
2. **Bump `version` and add exactly one migration path.** Room refuses to open a database whose
   stored version differs from the declared one with no route between them, and the exception names
   the versions.
3. **`AutoMigration` handles what Room can infer** — added columns with defaults, added tables,
   dropped tables. Declare it on the `@Database`: `autoMigrations = [AutoMigration(from = 1, to =
   2)]`.
4. **Ambiguous changes need a spec class.** A rename looks like a drop plus an add, so Room asks:
   `AutoMigration(from = 1, to = 2, spec = RenameSpec::class)` where the spec carries
   `@RenameColumn(tableName = "orders", fromColumnName = "total", toColumnName = "total_cents")`,
   `@DeleteColumn`, `@RenameTable` or `@DeleteTable`.
5. **Anything that transforms data is a hand migration.** Splitting a column, computing a default
   from another table, changing a type: `object : Migration(1, 2) { override fun migrate(db:
   SupportSQLiteDatabase) { … } }` on Room 2.6+ — on Room 2.7's KMP targets the parameter is a
   `SQLiteConnection` and the statements go through `execSQL` on it.
6. **SQLite cannot drop or alter a column before 3.35**, so Room's own generated path for those is
   create-new-table, copy, drop, rename. A hand migration doing the same must recreate indices and
   foreign keys too — which is exactly why the auto-migration is preferable when it applies.
7. **`fallbackToDestructiveMigration()` never ships.** It deletes the database on any version bump
   it has no path for: the user's offline drafts, their queued writes, their local history, gone
   with no message. `fallbackToDestructiveMigrationFrom(...)` for a specific dead version is the
   narrow, deliberate exception.

## SQLDelight

```sql
-- src/commonMain/sqldelight/migrations/1.sqm — migrates version 1 to version 2
ALTER TABLE orderRecord ADD COLUMN totalCents INTEGER NOT NULL DEFAULT 0;
```

1. **The number in the filename is the version it migrates *from*.** `1.sqm` takes a database at
   version 1 to version 2; `2.sqm` takes 2 to 3. Off-by-one here is the most common SQLDelight
   migration bug and it looks correct in the directory listing.
2. **The `.sq` files always describe the current schema.** Change the `CREATE TABLE` there *and*
   add the `.sqm`: the `.sq` file is what the generated code is typed against, the `.sqm` is what an
   existing database is walked through.
3. **`verifyMigrations = true` makes the build check them.** The Gradle task is
   `verifySqlDelightMigration` in 1.x and `verify<DatabaseName>Migration` in 2.x; it applies the
   migrations to the previous schema snapshot and fails the build when the result does not match
   the current `.sq` files.
4. **Verification needs snapshots.** `schemaOutputDirectory` is where the generated `.db` files go;
   they are committed, and a new one is produced per released version — without them there is
   nothing to migrate *from*.
5. **`deriveSchemaFromMigrations = true` inverts the model:** the migrations become the source of
   truth and the schema is computed by replaying them, so the `.sq` files hold queries only. It is
   the right setting for a database that predates SQLDelight; it is a one-way door.
6. **`Schema.migrate(driver, oldVersion, newVersion)` is what runs at startup**, usually via
   `AndroidSqliteDriver(schema, context, name)` which does it for you. On other drivers you call it.

## Flyway and Liquibase

| Aspect | Flyway (SQL-first) | Liquibase (changelog-first) |
|---|---|---|
| Unit of change | a script, `V<version>__<description>.sql` | a `changeSet` with an `id` and an `author` |
| Written in | the database's own SQL | YAML, XML, JSON or SQL changesets |
| Ordering | the version in the filename | the order of `include`s in the master changelog |
| Identity | a checksum over the file contents | `id` + `author` + file path, plus a checksum |
| Repeatable work | `R__<description>.sql`, re-run when its checksum changes | `runOnChange: true` on the changeSet |
| Rollback | forward-only in the free edition; you write a new script | a `rollback` block per changeSet, run by `liquibase rollback` |
| Guards | none — the script either runs or fails | `preConditions` decide whether a changeSet applies |
| Portability | you own the dialect | the changelog abstracts most DDL across databases |
| Take it when | one database, the team writes SQL, and reviewing SQL is a feature | several database vendors, or rollback scripts are a requirement |

1. **Never edit a shipped script.** Both tools checksum what they applied; changing the file makes
   the next run fail validation on every environment that already ran it. The correction is a new
   script with the next version.
2. **`validateOnMigrate` is on by default and stays on.** It is the check that catches the edit
   above before the deploy touches data. `flyway repair` rewrites the recorded checksum and is for
   the one case where you know the change was a comment or a formatting fix.
3. **`baselineOnMigrate` adopts an existing database.** It records the current state as the baseline
   version so the tool does not try to run version 1 against tables that already exist. Set the
   `baselineVersion` explicitly; the default of 1 is rarely what you meant.
4. **Spring Boot runs the migration at startup, before JPA validates.** With
   `spring.jpa.hibernate.ddl-auto=validate` that ordering is the whole safety net: the schema is
   migrated, then the mapping is checked against it, and a mismatch fails the boot
   (`persistence-jvm-orm`).
5. **On Ktor there is no auto-run.** Call it in the module before routes are installed:
   `Flyway.configure().dataSource(ds).load().migrate()`. That placement is also rule 9.
6. **The migration runs once per deploy, not once per pod.** Several replicas starting together all
   try; both tools take a lock, so the others wait rather than corrupt — but a long migration then
   blocks every replica's startup, which is why `Zero-Downtime` below splits it out of the boot path.

## Zero-Downtime

During a rolling deploy the old code and the new code run against the same database at the same
time. Every migration must therefore be compatible with the version before it, which turns one
"rename a column" into four deploys:

| Deploy | Migration | Code |
|---|---|---|
| 1 — expand | add `total_cents`, nullable, no constraint | unchanged; still reads and writes `total` |
| 2 — dual write | none | writes both columns, reads `total` |
| 3 — backfill and switch | backfill `total_cents` in batches, then a `CHECK … NOT VALID`, `VALIDATE CONSTRAINT` and `SET NOT NULL` | reads `total_cents`, still writes both |
| 4 — contract | drop `total`, **after** the deploy has fully rolled out | writes only `total_cents` |

Step 4 is the one step whose migration must not run at the start of its deploy: while it rolls,
deploy 3's pods are still writing `total`. Ship step 4's code, wait for the rollout to finish, and
only then apply the drop — as a migration triggered at the end of the deploy, or as the first
migration of the next release.

1. **Additive changes are safe; destructive ones are not.** Adding a nullable column, adding a
   table, adding an index concurrently — all compatible with running code. Dropping, renaming,
   narrowing a type or adding a `NOT NULL` without a default are not.
2. **Never rename in place.** `ALTER TABLE … RENAME COLUMN` is atomic in the database and
   catastrophic in a rolling deploy: every pod still running the old code breaks the instant it
   commits.
3. **One deploy per step, and each deploy is independently revertable.** The reason the table has
   four rows and not two is that a rollback of deploy 3 must land on a database deploy 2's code can
   still serve.
4. **The backfill is not part of the migration script** once the table is large — see
   `Long Migrations And Recovery`.
5. **`CREATE INDEX CONCURRENTLY` on Postgres, outside a transaction.** A plain `CREATE INDEX` takes
   a write lock for the duration; Flyway needs the script marked so it does not wrap it in one.
6. **`SET NOT NULL` scans the table under `ACCESS EXCLUSIVE`.** Add a
   `CHECK (col IS NOT NULL) NOT VALID` first, `VALIDATE CONSTRAINT` it under a lock that lets reads
   and writes through, and the `SET NOT NULL` that follows is metadata-only on Postgres 12+.
7. **`ADD COLUMN … NOT NULL DEFAULT <non-volatile>` is metadata-only on Postgres 11+**, and a full
   table rewrite before that and on some other engines. It is a different statement from the one
   above, with a different cost; check your version before assuming either step is free.

## Progressive Migration

A user can be on any previously shipped version, and a database can be restored from any backup.

1. **Migrate between adjacent versions.** One migration per version pair, applied in sequence — not
   one mapping from v1 to current, which has to be rewritten and re-tested on every release and
   is only ever exercised by the users who skipped the most releases.
2. **Never delete an old migration or an old exported schema.** They are the only route for a
   device that has been offline for a year. On the server they are the only route for a restored
   backup.
3. **Every shipped migration is tested against the fixture of the version before it**, so the chain
   is verified pairwise, and once end to end (`Testing`).
4. **The chain has to be idempotent under interruption.** Room and Flyway both record what was
   applied; a hand-written multi-statement migration that is not in one transaction can leave the
   database between versions if the process dies.
5. **A shared client database means either process may migrate first.** An Android app whose
   database is opened by a widget, a `WorkManager` job or a content provider must run the same
   migration gate wherever the database is opened first.

## Long Migrations And Recovery

1. **Back up before anything heavyweight or chained.** On a device, copy the database file and
   replace it atomically on success. On a server, take a snapshot and know how long a restore
   takes before you need it.
2. **Backfill in batches, not in one statement.** `UPDATE … WHERE id BETWEEN ? AND ?` in chunks of a
   few thousand, committed per batch, with a bounded pause between them — one `UPDATE` over ten
   million rows holds locks and bloats the write-ahead log until something gives.
3. **Make the backfill resumable and re-runnable.** A cursor row, or a `WHERE new_column IS NULL`
   predicate, so the job can be killed and restarted without redoing or skipping work.
4. **Set `lock_timeout` and `statement_timeout` on Postgres before DDL.** A migration that cannot
   take its lock in two seconds should fail fast; without a timeout it queues behind a long read
   and every query arriving after it queues behind the migration.
5. **Long work does not belong in the deploy's migration step.** Ship the schema change, then run
   the backfill as a job you can watch, throttle and stop (`release-ops-server`).
6. **On a client, show progress and defer background launches.** A migration on a cold start with
   no UI looks like a hang, and one started by a background job may be killed mid-way.
7. **The way back is a new forward migration.** Flyway's community edition has no undo, an app
   update cannot be un-installed from users' devices, and a rollback script that has never been run
   is not a rollback plan. Plan the fix as the next version, and keep the backup for support even
   when the user chooses to start fresh.

## Testing

1. **Every shipped migration has a test.** This is the rule that makes the rest of the discipline
   affordable, and it is the one skipped when a release is late.
2. **Room: a fixture database at the old version.** `MigrationTestHelper` (from
   `androidx.room:room-testing`) creates it from the exported schema, you write rows into it, then
   run the migration and assert on the result. Keep created fixtures under
   `androidTest/assets/`; never regenerate an old fixture with current code.
3. **Assert on data, not just on "it opened".** Row counts, transformed values, relations still
   intact, indices present, nothing lost. A migration that drops a column instead of copying it
   passes any test that only checks the version number.
4. **SQLDelight: the verification task is the test** for schema shape, and a JVM test against
   `JdbcSqliteDriver` with an old snapshot is the test for data.
5. **Server: a Testcontainers instance seeded from an old dump.** `withInitScript(...)` for a small
   one, `pg_restore` into the started container for a real one, then run the whole chain and assert
   both the data and the bookkeeping table — `flyway_schema_history` or `DATABASECHANGELOG`.
6. **Test the chain, not only the newest step.** Latest-version-only tests pass while the path a
   two-releases-behind user or a restored backup takes is never executed.
7. **Run the migration test in CI on every push**, not in a nightly job. Its whole value is failing
   before the release branch is cut (`release-ops`).

## Common Mistakes

1. **`exportSchema = false`, or `schemaDirectory` never configured.** It silences a build warning
   and removes the input every auto-migration and every migration test needs. It is discovered
   exactly at the moment it can no longer be fixed — when the un-exported version is on devices.
2. **`fallbackToDestructiveMigration()` in a release build.** The first version bump without a path
   wipes the user's data silently. It is in the codebase because it made a development crash go
   away, and nobody removed it.
3. **Editing a shipped migration.** The checksum no longer matches, so every environment that
   already ran it fails validation on the next deploy — and the environments that had not run it
   get a different schema from the ones that had. Corrections are new migrations.
4. **A rename shipped in one deploy.** For the length of the rolling deploy, half the pods query a
   column that no longer exists. The fix is four deploys (`Zero-Downtime`), and it costs a day
   instead of an outage.
5. **A backfill inside the migration script.** The deploy's migration step now holds locks for
   however long ten million rows take, every replica's startup waits on it, and there is no way to
   pause or resume. Schema change in the migration, data movement in a job.
6. **One mega-migration from the oldest version to current.** It is rewritten every release, tested
   by nobody, and run only by the users furthest behind — the ones least able to report what broke.
7. **`ddl-auto=update` beside a migration tool.** Two things now own the schema and they disagree
   quietly: Hibernate adds what it can infer, the migration files say something else, and no
   environment matches another.
8. **No test until the first migration goes wrong.** The migration that needed the test is the one
   already on users' devices, and the test written afterwards proves only that the fix works.
9. **The `.sqm` numbered for the version it produces.** A file written as `2.sqm` for "the change
   that makes version 2" runs on the 2→3 transition instead of 1→2: the change lands a version
   late, the 1→2 step is empty, and a database walking the chain arrives at the current version
   with exactly that column missing.
10. **Migrations skipped in the test database.** A suite that builds its schema from
    `SchemaUtils.create` or `ddl-auto=create-drop` tests a schema no environment has, and the first
    thing it stops catching is a migration that never ran.
