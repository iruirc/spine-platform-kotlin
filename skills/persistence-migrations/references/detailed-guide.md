# persistence-migrations — detailed guide

## Contents

- The Discipline
- Room — Exported Schemas
- Room — A Hand-Written Migration
- Room — AutoMigration and Specs
- Room — MigrationTestHelper
- SQLDelight — .sqm Files and Verification
- Flyway — Scripts and Wiring
- Liquibase — Changelog and Changesets
- Expand and Contract Across Four Deploys
- Server — Chain Test From an Old Dump

## The Discipline

Everything here assumes the discipline in the skill body. In particular: nothing below edits a file
that has shipped, and every version pair has a test.

## Room — Exported Schemas

```kotlin
// build.gradle.kts
plugins {
    id("androidx.room")
    id("com.google.devtools.ksp")
}

room { schemaDirectory("$projectDir/schemas") }

dependencies {
    implementation("androidx.room:room-runtime:<version>")
    ksp("androidx.room:room-compiler:<version>")
    androidTestImplementation("androidx.room:room-testing:<version>")
}
```

<!-- compile: android -->
```kotlin
@Database(entities = [OrderEntity::class], version = 2, exportSchema = true)
abstract class AppDatabase : RoomDatabase() {
    abstract fun orderDao(): OrderDao
}
```

The build now writes one JSON file per version under the schema directory:

```text
schemas/com.example.db.AppDatabase/1.json
schemas/com.example.db.AppDatabase/2.json
```

Both are committed. `1.json` is the input a migration test reads to build a version-1 fixture, and
the pair `(1.json, 2.json)` is what Room diffs to generate an auto-migration. Deleting `1.json`
after shipping version 2 removes the only description of the schema still on the devices that have
not updated.

Before the `androidx.room` Gradle plugin (Room 2.6), the directory was set through a KSP argument
(`ksp { arg("room.schemaLocation", "$projectDir/schemas") }`) and the directory had to be added to
the source sets by hand. New code uses the plugin.

## Room — A Hand-Written Migration

Anything that transforms data — a split, a merge, a type change, a computed default — is written
out. Room does not infer it and will not try.

<!-- compile: android -->
```kotlin
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

val MIGRATION_1_2 = object : Migration(1, 2) {
    override fun migrate(db: SupportSQLiteDatabase) {
        // SQLite fills the rows that exist with the DEFAULT; NOT NULL without one is rejected.
        db.execSQL("ALTER TABLE orders ADD COLUMN total_cents INTEGER NOT NULL DEFAULT 0")
        // Then the transform: cents from a REAL currency column, rounded once, here.
        db.execSQL("UPDATE orders SET total_cents = CAST(ROUND(total * 100) AS INTEGER)")
        db.execSQL("CREATE INDEX IF NOT EXISTS index_orders_placed_at ON orders(placed_at)")
    }
}

fun buildDatabase(context: Context): AppDatabase =
    Room.databaseBuilder(context, AppDatabase::class.java, "app.db")
        .addMigrations(MIGRATION_1_2, MIGRATION_2_3)   // adjacent pairs; Room walks the chain
        .build()
```

Room runs each `migrate` inside a transaction it owns, so a failure part-way leaves the database at
the old version rather than between two. What it does *not* do is check your SQL: after the
migration Room validates the resulting schema against the exported JSON for the new version, and a
mismatch is `IllegalStateException: Migration didn't properly handle: orders(...)` naming the
column that differs — usually a missing index or a nullability that does not match the entity.

Dropping a column needs SQLite 3.35, which arrives with Android 14 (API 34, SQLite 3.39). Below
that baseline it is the four-step dance — here dropping `total` once `total_cents` has taken over:

<!-- compile: android -->
```kotlin
val MIGRATION_2_3 = object : Migration(2, 3) {
    override fun migrate(db: SupportSQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE orders_new (id TEXT NOT NULL PRIMARY KEY, " +
                "placed_at INTEGER NOT NULL, total_cents INTEGER NOT NULL)",
        )
        db.execSQL(
            "INSERT INTO orders_new (id, placed_at, total_cents) " +
                "SELECT id, placed_at, total_cents FROM orders",
        )
        db.execSQL("DROP TABLE orders")
        db.execSQL("ALTER TABLE orders_new RENAME TO orders")
        db.execSQL("CREATE INDEX index_orders_placed_at ON orders(placed_at)")   // indices do not survive
    }
}
```

The new table carries every column the entity still has, `placed_at` included: the index recreated
on a column the copy left out fails with `no such column`.

On Room 2.7's KMP targets the signature is `override fun migrate(connection: SQLiteConnection)`,
and statements go through `connection.execSQL(...)`. Everything else is the same.

## Room — AutoMigration and Specs

When the change is one Room can compute from the two exported JSON files, declare it and write no
SQL:

```kotlin
@Database(
    entities = [OrderEntity::class],
    version = 2,
    exportSchema = true,
    autoMigrations = [AutoMigration(from = 1, to = 2, spec = AppDatabase.RenameNote::class)],
)
abstract class AppDatabase : RoomDatabase() {
    // A rename only: TEXT stays TEXT, so the renamed column still fits the entity's field.
    @RenameColumn(tableName = "orders", fromColumnName = "note", toColumnName = "customer_note")
    @DeleteColumn(tableName = "orders", columnName = "legacy_flag")
    class RenameNote : AutoMigrationSpec {
        // Optional: runs after the generated statements, for data work the diff cannot express.
        override fun onPostMigrate(db: SupportSQLiteDatabase) {
            db.execSQL("UPDATE orders SET customer_note = trim(customer_note)")
        }
    }
}
```

- **No spec is needed for unambiguous changes** — a new table, a new column with a default, a
  dropped table. `AutoMigration(from = 1, to = 2)` alone covers those.
- **A spec is required the moment the diff is ambiguous.** A rename is indistinguishable from a drop
  plus an add, so without `@RenameColumn` Room's processor fails the build with
  `AutoMigration Failure: Please declare an interface extending 'AutoMigrationSpec'` — it never
  guesses the destructive reading.
- **A rename keeps the column's type.** `@RenameColumn` emits a rename, not a conversion, which is
  why `total` (REAL) cannot become `total_cents` (INTEGER) this way: the migration would run and
  then fail Room's validation against a `Long` field. That change is the hand migration above.
- **The annotations available are `@RenameColumn`, `@DeleteColumn`, `@RenameTable` and
  `@DeleteTable`.** Anything else — a type change, a split, a value computed from another table — is
  a hand migration, or an `onPostMigrate` body on columns whose type did not move.
- **A hand migration for the same version pair replaces the auto-migration, silently.** Room adds
  the generated one only for a pair no `addMigrations` call covers, so the auto-migration's
  `onPostMigrate` never runs either. Keep one per pair.
- **Auto-migrations still need tests.** They are generated from JSON, not from your intent, and
  `@DeleteColumn` on the wrong column compiles perfectly.

## Room — MigrationTestHelper

```kotlin
@RunWith(AndroidJUnit4::class)
class OrderMigrationTest {
    private val dbName = "migration-test.db"

    @get:Rule
    val helper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        AppDatabase::class.java,        // reads schemas/ via the exported JSON on the test assets
    )

    @Test
    fun migrate1To2_convertsTotalToCents() {
        // Version 1, built from 1.json — not from today's entities.
        helper.createDatabase(dbName, 1).use { db ->
            db.execSQL("INSERT INTO orders (id, total) VALUES ('o-1', 12.34)")
        }

        val db = helper.runMigrationsAndValidate(dbName, 2, true, MIGRATION_1_2)

        db.query("SELECT total_cents FROM orders WHERE id = 'o-1'").use { c ->
            assertTrue(c.moveToFirst())
            assertEquals(1234, c.getInt(0))     // the value, not just the schema
        }
    }
}
```

- **`createDatabase(name, 1)` builds the old schema from the exported JSON.** This is why the export
  is not optional and why old JSON files are never deleted.
- **`runMigrationsAndValidate(..., validateDroppedTables = true, ...)` does two jobs**: it applies
  the migrations and then checks the result against the new version's JSON. A pass means the schema
  matches; only your assertions say the data survived.
- **Assert on data.** A migration that creates `total_cents` and never fills it passes schema
  validation and loses every order total in the product.
- **A fixture file is an alternative to `createDatabase`** when you want a real database captured
  from an old release: put the `.db` under `androidTest/assets/`, copy it into place in the test,
  and never regenerate it with current code.
- **Auto-migrations are tested the same way**, passing no `Migration` objects:
  `runMigrationsAndValidate(dbName, 2, true)`.
- **On Room 2.7 KMP the helper takes a driver and a file path** instead of the instrumentation
  handle; the shape of the test is unchanged. Check the signature against the version you are on.

## SQLDelight — .sqm Files and Verification

```kotlin
// build.gradle.kts
sqldelight {
    databases {
        create("AppDatabase") {
            packageName.set("com.example.db")
            schemaOutputDirectory.set(file("src/commonMain/sqldelight/databases"))
            verifyMigrations.set(true)
        }
    }
}
```

The `.sq` files always describe the schema *as it is now*; the `.sqm` files describe how to get
there from each earlier version.

```sql
-- src/commonMain/sqldelight/com/example/db/Order.sq — the current schema
import kotlin.time.Instant;

CREATE TABLE orderRecord (
  id         TEXT NOT NULL PRIMARY KEY,
  customerId TEXT NOT NULL,
  placedAt   INTEGER AS Instant NOT NULL,
  totalCents INTEGER NOT NULL DEFAULT 0
);
```

```sql
-- src/commonMain/sqldelight/migrations/1.sqm — applied to a database AT version 1
ALTER TABLE orderRecord ADD COLUMN totalCents INTEGER NOT NULL DEFAULT 0;
```

- **The filename is the source version.** `1.sqm` runs against version 1 and produces version 2.
  The database version is the highest `.sqm` number plus one, and SQLDelight derives it — you never
  write a version constant. The verification task rejects a gap in the numbering.
- **`schemaOutputDirectory` adds the task that writes a snapshot.** `generateCommonMainAppDatabaseSchema`
  writes the current schema as `<version>.db` into that directory. Run it before the first `.sqm`
  and commit the `1.db`; verification replays every `.sqm` from it, so one snapshot covers the
  chain. Each extra `.db` is replayed as well and only costs build time.
- **The verification task always runs in `check`.** `verifyCommonMainAppDatabaseMigration` here —
  `verifyMainAppDatabaseMigration` in a JVM module, `verify<Variant>AppDatabaseMigration` on Android —
  and `verifySqlDelightMigration` runs every one. It applies the `.sqm` files to each committed
  `.db` and fails when the result does not match the current `.sq` schema.
- **`verifyMigrations = true` makes a broken migration fail the build**: an error inside a `.sqm`, or
  no `.db` to replay it on. Left off, a module with no snapshot passes verification without
  checking anything.
- **Verification checks shape, never data.** A `.sqm` that adds the column but leaves it empty
  passes; a JVM test with `JdbcSqliteDriver`, an old snapshot and real rows is what catches that.
- **`deriveSchemaFromMigrations = true` flips the model**: the `.sq` files hold queries only, the
  schema is whatever replaying every `.sqm` produces. It suits a database SQLDelight adopted rather
  than created, and it is not a setting to change twice.
- **Migration runs through the driver.** `AndroidSqliteDriver(Schema, context, "app.db")`,
  `NativeSqliteDriver(Schema, "app.db")` and `JdbcSqliteDriver(url, properties, Schema)` each call
  `Schema.migrate(...)` for you, from the version in `PRAGMA user_version` — the JDBC driver only
  when it is built with the schema. A call of your own on top walks the chain a second time.

## Flyway — Scripts and Wiring

Scripts live on the classpath under `db/migration` and are named for their version:

```text
src/main/resources/db/migration/V1__init.sql
src/main/resources/db/migration/V2__add_total_cents.sql
src/main/resources/db/migration/V3__index_orders_placed_at.sql
src/main/resources/db/migration/V3__index_orders_placed_at.sql.conf
src/main/resources/db/migration/R__order_summary_view.sql
```

`V` is versioned (runs once, in version order), `R` is repeatable (runs after all versioned
scripts, and again whenever its checksum changes — views, functions, seed data). Two underscores
separate the version from the description; one underscore is a file Flyway ignores.

```sql
-- V2__add_total_cents.sql — additive only: the previous release still runs against this.
ALTER TABLE orders ADD COLUMN total_cents BIGINT;
```

```sql
-- V3__index_orders_placed_at.sql — alone: it cannot share a transaction, or a script, with others.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_placed_at ON orders (placed_at);
```

```properties
# V3__index_orders_placed_at.sql.conf
executeInTransaction=false
```

`CREATE INDEX CONCURRENTLY` cannot run inside a transaction, and Flyway will not split a script for
it. With V2's `ALTER TABLE` in the same file the migration stops with
`Detected both transactional and non-transactional statements within the same migration`. Alone in
its script, the statement is recognised and run outside a transaction without further help; the
`.sql.conf` beside it says so explicitly. Open-source Flyway does not read a
`-- flyway:executeInTransaction=false` line at the top of the script, and the mixed script fails
with it all the same.

The index also needs Flyway's session-level lock. By default Flyway guards the migration with a
transactional advisory lock, held by a transaction that stays open on a second connection until
the run ends — and `CONCURRENTLY` waits for every open transaction, so the migration never
finishes. `postgresql.transactional.lock=false` switches to a session lock; the Boot property and
the Ktor call are below.

On Spring Boot 4 Flyway runs at startup, before Hibernate validates, only with
`spring-boot-starter-flyway`: `flyway-core` alone boots and migrates nothing. On PostgreSQL the
database plugin sits beside it, or Flyway stops with `Unsupported Database: PostgreSQL …`. Boot's
BOM manages Flyway's version, so neither alias carries one:

<!-- compile: catalog -->
```toml
[libraries]
spring-boot-starter-flyway = { module = "org.springframework.boot:spring-boot-starter-flyway" }
spring-flyway-database-postgresql = { module = "org.flywaydb:flyway-database-postgresql" }
```

```yaml
spring:
  flyway:
    enabled: true
    validate-on-migrate: true      # default; the check that catches an edited script
    baseline-on-migrate: false     # true only to adopt a database that predates Flyway
    baseline-version: 4            # and then say which version it already is
    postgresql:
      transactional-lock: false    # CREATE INDEX CONCURRENTLY never finishes under the default
  jpa:
    hibernate:
      ddl-auto: validate           # the mapping is checked against the migrated schema
```

On Ktor there is no auto-run, so the module does it before installing routes, with `flyway-core`
and `flyway-database-postgresql` at one pinned version:

<!-- compile: ktor -->
```kotlin
import com.zaxxer.hikari.HikariDataSource
import org.flywaydb.core.Flyway
import org.flywaydb.database.postgresql.PostgreSQLConfigurationExtension

fun Application.module() {
    val dataSource = HikariDataSource(hikariConfig())
    val flyway = Flyway.configure().dataSource(dataSource)
    flyway.getConfigurationExtension(PostgreSQLConfigurationExtension::class.java)
        .isTransactionalLock = false   // for CREATE INDEX CONCURRENTLY
    flyway.load().migrate()   // rule 9, server-side
    configureRouting(dataSource)
}
```

- **`flyway_schema_history` records every applied script with its checksum.** Editing a shipped
  file changes the checksum and the next `migrate` fails validation — which is the feature.
- **`flyway repair` rewrites recorded checksums** and is for the case where you know the change was
  cosmetic. It is not a way to make a real edit acceptable.
- **`outOfOrder` is off by default.** Two branches that both add `V5__` merge into a conflict you
  want to see at build time, not a script that silently never runs.
- **Migrations lock.** Several replicas starting at once contend on Flyway's lock and the losers
  wait — safe, but it makes every pod's startup as slow as the migration, which is why long work is
  a separate job.

## Liquibase — Changelog and Changesets

A master changelog includes one file per change, in the order they must run:

```yaml
# src/main/resources/db/changelog/db.changelog-master.yaml
databaseChangeLog:
  - include: { file: db/changelog/001-init.yaml }
  - include: { file: db/changelog/002-add-total-cents.yaml }
  - include: { file: db/changelog/003-backfill-total-cents.yaml }
```

One `include` per change, appended at the end — never a reordering. `includeAll` runs a directory
in the lexicographic order of the file paths, so it holds only while every name sorts where it must
run: `10-…` sorts before `9-…` unless the prefixes are zero-padded.

```yaml
# 002-add-total-cents.yaml
databaseChangeLog:
  - changeSet:
      id: 002-add-total-cents
      author: orders-team
      preConditions:
        - onFail: MARK_RAN            # already there? record it and move on
        - not:
            - columnExists: { tableName: orders, columnName: total_cents }
      changes:
        - addColumn:
            tableName: orders
            columns:
              - column: { name: total_cents, type: BIGINT }
      rollback:
        - dropColumn: { tableName: orders, columnName: total_cents }
```

- **Identity is `id` + `author` + file path.** Change any of the three and Liquibase treats it as a
  new changeset and runs it again; change the *body* and the checksum check fails, exactly as
  Flyway's does.
- **`preConditions` decide whether a changeset applies**, with `onFail` choosing what happens when
  they do not hold: `HALT` (default), `MARK_RAN`, `CONTINUE`, `WARN`. `MARK_RAN` above makes the
  changeset safe to apply to a database somebody already patched by hand.
- **Write the `rollback` block, or say there is none.** Liquibase infers it for simple changes and
  cannot for `sql` changes; `rollback: empty` is how you state deliberately that a changeset is
  forward-only. An inferred rollback that has never been executed is not a tested rollback.
- **`runOnChange: true` is the repeatable-script equivalent** — a view or a stored procedure whose
  definition lives in one place and is re-applied when it changes.
- **`DATABASECHANGELOG` is the bookkeeping table** (and `DATABASECHANGELOGLOCK` the lock). It is
  what a chain test asserts on, and what tells you which environment is where.
- **The YAML abstracts DDL across vendors**, which is the reason to be here; a raw `sql` changeset
  gives that up for one change, which is fine as long as it is a choice.

## Expand and Contract Across Four Deploys

The change: `orders.total` (a `NUMERIC`) becomes `orders.total_cents` (a `BIGINT`). During every
rolling deploy the previous version's code is still serving traffic, so no single step may break
it.

```sql
-- Deploy 1 — V10__expand_total_cents.sql. Additive, nullable, no constraint.
ALTER TABLE orders ADD COLUMN total_cents BIGINT;
```

Deploy 1 ships the migration alone: the running code neither knows nor cares about the new column.
Reverting it is free.

```kotlin
// Deploy 2 — code only, no migration. Write both, read the old one.
fun place(order: Order) = dsl.insertInto(ORDERS)
    .set(ORDERS.TOTAL, order.total.asDecimal())
    .set(ORDERS.TOTAL_CENTS, order.total.cents)       // new column, not yet read
    .execute()
```

Now every row written by the new code has both values. Rows written before deploy 1, and by pods
still on the old version during deploy 2, have `total_cents` null — which is why the constraint
cannot exist yet.

```sql
-- Deploy 3 — V11__check_total_cents.sql, after the backfill job. Metadata only: no scan.
SET LOCAL lock_timeout = '2s';
ALTER TABLE orders ADD CONSTRAINT total_cents_nn CHECK (total_cents IS NOT NULL) NOT VALID;

-- V12__validate_total_cents.sql — the scan, under SHARE UPDATE EXCLUSIVE: reads and writes go on.
ALTER TABLE orders VALIDATE CONSTRAINT total_cents_nn;

-- V13__total_cents_not_null.sql — Postgres 12+ trusts the valid check and skips the scan.
SET LOCAL lock_timeout = '2s';
ALTER TABLE orders ALTER COLUMN total_cents SET NOT NULL;
ALTER TABLE orders DROP CONSTRAINT total_cents_nn;
```

Three scripts, because a lock lasts until its transaction commits and Flyway commits each versioned
script on its own (unless `group` is on). `ADD CONSTRAINT` takes `ACCESS EXCLUSIVE` for an instant;
written in one script with the `VALIDATE`, it keeps that lock through the whole scan, and every read
and write of `orders` queues behind it. `SET NOT NULL` needs `ACCESS EXCLUSIVE` too, but only after
the scan is over. `lock_timeout` makes either of them fail fast instead of queueing every query
behind a lock it is still waiting for.

The backfill itself runs as a job between deploy 2 and deploy 3, in batches:

```sql
UPDATE orders SET total_cents = CAST(ROUND(total * 100) AS BIGINT)
WHERE total_cents IS NULL AND id IN (
  SELECT id FROM orders WHERE total_cents IS NULL ORDER BY id LIMIT 5000
);
```

Run until it affects zero rows, with a pause between batches. `WHERE total_cents IS NULL` makes it
resumable and re-runnable: killing it loses nothing. Only when it reports zero remaining does
deploy 3's `VALIDATE` succeed — and deploy 3's code reads `total_cents` while still writing both.

```sql
-- Deploy 4 — V14__contract_total.sql, run only once deploy 4 has fully rolled out.
ALTER TABLE orders DROP COLUMN total;
```

Deploy 4 is the one step whose code must land before its migration. While the rollout is in
progress, deploy 3's pods are still writing `total`, so a drop applied at the start of the deploy —
which is where Boot, Ktor and every CI pipeline apply migrations by default — breaks them for the
length of the rollout. Ship deploy 4 as code only, wait for the last old pod to go, then apply the
drop: triggered by hand at the end of the deploy, or carried as the first migration of the next
release.

- **Each deploy is independently revertable.** Reverting deploy 3's code lands on a database deploy
  2's code can still serve, because both columns are present and both are written.
- **The drop waits for evidence, not for a calendar.** Check that no code path writes `total` —
  grep, plus a log line or a metric on the write path in deploy 3 — and that no pod from deploy 3
  is left, before dropping it.
- **`ALTER TABLE … RENAME COLUMN` would have been one line and an outage.** It is atomic, and every
  pod on the previous version starts failing the instant it commits.
- **`ADD COLUMN … NOT NULL DEFAULT <non-volatile>` is metadata-only on Postgres 11+** and a full
  table rewrite before that, and on some other engines still. That is a different statement from
  deploy 3's `SET NOT NULL`, which has its own cost and its own workaround above — know which one
  you are writing before assuming a step is free.
- **On a client the same shape applies to a different clock**: the "previous version" is the app
  release users have not installed yet, and deploy 4 is the release after the one where telemetry
  says the old column is unread.

## Server — Chain Test From an Old Dump

The migration that matters is the one applied to the schema production actually has, which is
rarely the one a fresh `migrate` produces. The test starts a container from an old dump and runs
the whole chain.

<!-- compile: spring-test -->
```kotlin
import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import javax.sql.DataSource
import org.assertj.core.api.Assertions.assertThat
import org.flywaydb.core.Flyway
import org.testcontainers.utility.DockerImageName

@Testcontainers
class MigrationChainTest {
    companion object {
        // withInitScript is enough for a small, committed dump; a real one is restored below.
        @Container @JvmStatic
        val postgres = PostgreSQLContainer(DockerImageName.parse("postgres:16-alpine"))
            .withInitScript("dumps/production-v7.sql")
    }

    private val dataSource = HikariDataSource(HikariConfig().apply {
        jdbcUrl = postgres.jdbcUrl; username = postgres.username; password = postgres.password
    })

    @Test
    fun migrate_fromV7ToHead_keepsEveryOrder() {
        val before = dataSource.count("select count(*) from orders")

        val result = Flyway.configure().dataSource(dataSource).load().migrate()

        assertThat(result.migrationsExecuted).isGreaterThan(0)
        assertThat(dataSource.count("select count(*) from orders")).isEqualTo(before)
        assertThat(dataSource.count("select count(*) from orders where total_cents is null"))
            .isZero()
        // The bookkeeping table is part of the assertion: nothing pending, nothing failed.
        assertThat(dataSource.count("select count(*) from flyway_schema_history where not success"))
            .isZero()
    }

    private fun DataSource.count(sql: String): Long = connection.use { c ->
        c.createStatement().use { st -> st.executeQuery(sql).use { rs -> rs.next(); rs.getLong(1) } }
    }
}
```

The container and why the test database is never H2: `persistence-jvm-orm` → "Testing".

For a dump too large to commit, restore it into the started container instead of using
`withInitScript`:

```kotlin
postgres.copyFileToContainer(MountableFile.forHostPath(dumpPath), "/tmp/dump.pgc")
postgres.execInContainer(
    "pg_restore", "-U", postgres.username, "-d", postgres.databaseName, "/tmp/dump.pgc",
)
```

- **Anonymise the dump once, in the fixture, and commit the anonymised one.** A production dump in
  a test resource is a data-protection incident waiting for a repository to go public.
- **Assert on data and on bookkeeping.** Row counts before and after, the transformed values, no
  nulls where a `NOT NULL` is about to be added, and every `flyway_schema_history` row successful —
  or, on Liquibase, the expected `DATABASECHANGELOG` ids present with no `MARK_RAN` you did not
  intend.
- **Keep one dump per still-supported starting point.** A dump at v7 tests the v7→head chain and
  nothing else; when a customer database is on v4, that is a second fixture.
- **Refresh the dump when a version falls out of support**, never by re-exporting a database the
  current code has already migrated — that produces a fixture which tests nothing.
- **This test belongs in CI on every push** (`release-ops-server`). It costs one container start,
  and it is the only place the path a real deploy takes is ever executed before the deploy.
