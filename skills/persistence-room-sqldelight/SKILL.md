---
name: persistence-room-sqldelight
description: "Use when choosing and implementing the local database in a Kotlin client — Room (Android, KMP since 2.7) vs SQLDelight (KMP-native, SQL-first). Covers the decision, entities/DAOs vs .sq files, relations, Flow queries, transactions, in-memory testing, and the migration hand-off."
---

# Room and SQLDelight

Two ways to put SQLite behind a repository: Room, which generates SQL access from annotated Kotlin,
and SQLDelight, which generates Kotlin from SQL you wrote. The decision, then the shape each one
imposes on the layer — entities and DAOs against `.sq` files, `Flow` queries, transactions, and the
in-memory database each is tested on. What sits above the database — the boundary and the
source-of-truth policy — is `persistence-architecture`, and it does not change with the answer here.

> **Related skills:**
> - `persistence-architecture` — the repository boundary this database hides behind, and the policy that decides what it holds
> - `persistence-migrations` — changing a shipped schema: exported schemas, `Migration`, auto-migrations and `.sqm` files
> - `arch-clean` — the entity/domain split, and why the mapper below is not boilerplate you can delete
> - `concurrency-coroutines` — the dispatcher each query runs on, and what a blocking query costs on the main thread
> - `reactive-flow` — sharing one database `Flow` across collectors, and the `started` policy over an open cursor
> - `pkg-kmp-source-sets` — where the common database code lives and where the per-target driver halves go
> - `di-hilt` — providing the one database instance on Android, at application scope
> - `di-koin` — the same single instance on KMP, with the driver supplied by a platform module

## When to Use

- A client needs its first local table and nobody has picked the library
- User asks "Room or SQLDelight", "does Room work on KMP now", "why is my `Flow` query not
  re-emitting", "where do I put the transaction", "how do I test a DAO without a device"
- A module holding a Room database is about to be shared with iOS or desktop
- Review finds `allowMainThreadQueries()`, `fallbackToDestructiveMigration()`, an entity in a
  composable signature, or `executeAsList()` on the main thread
- The symptom is an ANR on a list screen, a `@Relation` read that returns children inconsistent with
  their parent, or a test suite that needs an emulator to check one query

Not for what the database is *for* — offline policy, caching, the repository contract — which is
`persistence-architecture`. Not for schema change (`persistence-migrations`), not for a server's
database (`persistence-jvm-orm`), not for flags and settings (DataStore, in
`persistence-architecture`).

`references/detailed-guide.md` lies beside this file; its `## Contents` names the sections — read only the ones the table points to.

## When To Load The Reference

| Need | Reference sections |
|---|---|
| The shared `OrderRepository` port every engine section implements | `The Domain Side` |
| Declare a Room table, its indices and its DAO | `Room — Entity and DAO` |
| Wire the `RoomDatabase`, KSP and the Gradle plugin | `Room — Database and Wiring` |
| Map entities to domain and expose an observable read | `Room — Repository and Flow Queries` |
| Write across several DAO calls atomically | `Room — Transactions` |
| Test a DAO or a repository with no device | `Room — In-Memory Test` |
| Write the schema and the named queries SQLDelight generates from | `SQLDelight — The .sq File` |
| Apply the Gradle plugin and open a database on each target | `SQLDelight — Gradle and Drivers` |
| Turn a generated query into a domain `Flow` | `SQLDelight — Repository and Flow Queries` |
| Write across several generated queries atomically | `SQLDelight — Transactions` |
| Test on a JVM in-memory database | `SQLDelight — In-Memory Test` |
| Take Room into `commonMain` on 2.7+ | `Room on KMP` |

## Decision

| Situation | Take | Because |
|---|---|---|
| Android app, no shared code planned, team fluent in Jetpack | Room | the default everyone has already used: annotations, an `@Query` checked at compile time, `Flow` DAO functions, Paging and `MigrationTestHelper` all in the box |
| Kotlin Multiplatform, or the target list includes web | SQLDelight | it was multiplatform first: `commonMain` schema, a driver per target including `WebWorkerDriver`, and no annotation processor to run on Kotlin/Native |
| The team would rather read SQL than annotations, on any target | SQLDelight | the `.sq` file *is* the schema and the queries; nothing is generated from a shape you have to infer |
| A complex query surface — window functions, CTEs, `GROUP BY` with aggregates | SQLDelight | the compiler parses the SQL against the schema and types the result class for you; Room checks the string but returns whatever you declared |
| An existing Room codebase that now needs iOS, desktop or JVM | Room 2.7+ on KMP | the entities, DAOs and queries move as they are; the cost is the driver and KSP setup below, not a rewrite |
| A handful of flags or a settings object | neither | that is DataStore — see `persistence-architecture` |

Room on KMP (2.7 and later) is a real third option, with edges worth knowing before choosing it:

1. **The target list is Android, iOS, JVM/desktop and native — not web.** Room has no JS or Wasm
   target. A build that must run in a browser has one answer, and it is SQLDelight.
2. **KSP runs on every target.** Room's compiler is an annotation processor, so each target
   configures KSP; the Gradle plugin `androidx.room` plus `ksp(…room-compiler)` per source set is
   the setup, and it is more moving parts than SQLDelight's single plugin.
3. **Non-Android targets need a driver.** `androidx.sqlite:sqlite-bundled` ships SQLite with the
   app and provides `BundledSQLiteDriver`; the builder takes it through `setDriver(…)` and takes
   the query dispatcher through `setQueryCoroutineContext(…)`.
4. **`commonMain` needs the generated constructor.** The `@Database` class carries
   `@ConstructedBy(AppDatabaseConstructor::class)` and an `expect object AppDatabaseConstructor :
   RoomDatabaseConstructor<AppDatabase>` beside it; the `actual` is generated per target.
5. **`@Query` is validated at compile time on every target.** That is Room's central benefit and it
   survives the move: a typo in a column name is a build failure, not a runtime crash on a device.
6. **Migrations work, and so does testing them — check the constructor.** Exported schemas and
   `Migration` objects behave as on Android, and `androidx.room:room-testing` is published for the
   KMP targets from 2.7, so `MigrationTestHelper` is available in a multiplatform test: it takes the
   exported schema directory, the database file name and a driver instead of the instrumented
   `Context` the Android-only form took. Verify that signature against the 2.7 release notes before
   writing the test (`persistence-migrations`).
7. **Paging and `@Relation` are the other two to check, not to assume.** Room's Paging integration
   is an Android-shaped dependency, and support for parts of the annotation surface has landed
   target by target. Verify against the version you are on rather than against a blog post.
8. **Say the choice once, in the project guidance file.** Both libraries will otherwise arrive: one
   in the app module, one in a shared module, and the second one is always somebody's convenience.

## Room Shape

```kotlin
@Dao
interface OrderDao {
    // @Transaction because Room satisfies a @Relation with two statements, not one.
    @Transaction
    @Query("SELECT * FROM orders WHERE customer_id = :id ORDER BY placed_at DESC")
    fun observeByCustomer(id: String): Flow<List<OrderWithLines>>

    @Upsert suspend fun upsertOrder(order: OrderEntity)
}
```

1. **`@Entity` is the schema, not the model.** Table name, columns, indices and foreign keys, with a
   stable primary key — `@PrimaryKey val id: String` for data that syncs, `autoGenerate = true`
   only for rows that never leave the device. Index the columns a hot `WHERE` or `ORDER BY`
   actually uses, after measuring; each index costs every write.
2. **`@Dao` functions are `suspend` for one-shot work and `Flow<List<T>>` for observation.** A
   `Flow` DAO function re-emits whenever any table it touched is written, which is what makes
   database-first reads work; a `suspend` function runs on Room's own query executor.
3. **`@Query` strings are checked against the schema at build time.** A wrong column name, a missing
   table, a result shape that does not fit the return type — all build failures. This is the reason
   to be on Room, so do not defeat it with `@RawQuery` unless the query genuinely is dynamic.
4. **`@Transaction` on any DAO method that runs more than one statement**, and on every `@Relation`
   read. Room implements `@Relation` as a parent query plus a child query; without `@Transaction`
   a concurrent write between them returns children that never belonged to that parent.
5. **`@Insert(onConflict = OnConflictStrategy.REPLACE)` is a delete plus an insert**, not an update:
   `ON DELETE CASCADE` children disappear, and an autogenerated id changes. `@Upsert` (2.5+) is the
   one that updates in place, and is what most code meant.
6. **KSP, not kapt.** `ksp("androidx.room:room-compiler:<version>")` beside
   `implementation("androidx.room:room-runtime:<version>")`, plus `androidx.room:room-ktx` for
   `withTransaction` and the coroutine extensions.
7. **Apply the `androidx.room` Gradle plugin and set the schema directory:**
   `room { schemaDirectory("$projectDir/schemas") }`. The exported JSON is what auto-migrations are
   computed from and what migration tests read; committing it is `persistence-migrations`' subject
   and skipping it is the mistake that surfaces one release later.
8. **One database instance per process.** `Room.databaseBuilder(...)` is called once in the
   composition root and the result is a singleton — a second instance means a second connection
   pool and its own view of an open transaction (`di-hilt`, `di-koin`).

## SQLDelight Shape

```sql
-- src/commonMain/sqldelight/com/example/db/Order.sq
import kotlinx.datetime.Instant;

CREATE TABLE orderRecord (
  id         TEXT NOT NULL PRIMARY KEY,
  customerId TEXT NOT NULL,
  placedAt   INTEGER AS Instant NOT NULL
);

-- generates OrderQueries.selectByCustomer(customerId): Query<OrderRecord>
selectByCustomer:
SELECT * FROM orderRecord WHERE customerId = ? ORDER BY placedAt DESC;
```

1. **The `.sq` file is the source of truth.** It lives at
   `src/commonMain/sqldelight/<package>/<Name>.sq`, holds the `CREATE TABLE` statements and every
   named query, and the package directory has to match the `packageName` configured in Gradle.
2. **A query is a name, a colon and SQL.** `selectByCustomer:` above a `SELECT` generates a function
   on the generated `Queries` class, typed by the columns it actually selects; a `SELECT` of a
   subset generates a data class for that subset.
3. **The plugin is `app.cash.sqldelight`**, configured with
   `sqldelight { databases { create("AppDatabase") { packageName.set("com.example.db") } } }`. The
   database class it generates takes a driver: `AppDatabase(driver)`.
4. **Drivers are the per-target half**, and the only part that is not `commonMain`:
   `AndroidSqliteDriver` (`android-driver`), `NativeSqliteDriver` (`native-driver`, iOS and macOS),
   `JdbcSqliteDriver` (`sqlite-driver`, JVM and desktop), `WebWorkerDriver` (`web-worker-driver`).
   The common code declares an `expect` factory; each target's `actual` builds its driver
   (`pkg-kmp-source-sets`).
5. **Generated queries are blocking.** `executeAsList()`, `executeAsOne()` and
   `executeAsOneOrNull()` run on the calling thread, so every call site is inside
   `withContext(io)` — SQLDelight will not move you off the main thread and will not complain.
6. **Observation is `asFlow().mapToList(dispatcher)`**, from the
   `app.cash.sqldelight:coroutines-extensions` artifact. The dispatcher argument is where the query
   actually runs; passing `Dispatchers.Main` there is an ANR with no warning. `mapToOne`,
   `mapToOneOrNull` and `mapToOneNotNull` are the single-row forms.
7. **SQLite has no date, no boolean and no enum**, so the schema declares an adapter:
   `createdAt INTEGER AS Instant NOT NULL` in the `.sq` file — the Kotlin type imported at the top
   of the file, the `ColumnAdapter` passed to the database constructor. Keeping that mapping in one
   place is what stops half the codebase parsing timestamps by hand.
8. **Schema changes are `.sqm` files** numbered by version, verified by the plugin's
   `verify<SourceSet><Database>Migration` task — `persistence-migrations`.

## Transactions

Which layer opens one is `persistence-architecture` → "Transaction Boundary"; this section is how
each engine spells it.

1. **A transaction is what makes two writes one write.** Insert an order and its lines, mark a row
   synced and delete its outbox entry, replace a page of a list — each is one unit whose partial
   application is a corrupt state your UI will render.
2. **Room, inside one DAO: `@Transaction`.** The generated implementation wraps the method body,
   which is why an `@Transaction` method may call other DAO methods of the same DAO.
3. **Room, across DAOs or with logic between the writes: `db.withTransaction { }`** from
   `room-ktx`. It is `suspend`, it is coroutine-aware, and it is the only correct way to hold a
   transaction across a `suspend` call. `runBlocking` inside a transaction block deadlocks against
   Room's own dispatcher — a real one, not a theoretical one.
4. **SQLDelight: `transaction { }` on the database or on a generated `Queries` object**, and
   `transactionWithResult { }` when the block produces a value. `rollback()` aborts it explicitly.
5. **SQLDelight's transaction block is not `suspend`.** You cannot call a suspending function
   inside it, which is a feature: it stops a network call from being awaited while a write
   transaction is open. Run the whole block inside `withContext(io)` instead.
6. **`afterCommit { }` and `afterRollback { }` are for effects that must not run early** — a cache
   invalidation, an analytics event, a notification. Firing them inside the block means firing them
   for a transaction that then rolls back.
7. **Keep transactions short and free of anything that can block.** A write transaction holds the
   database; a network call, a file read or a user prompt inside one turns a hundred milliseconds
   into a lock every other query waits on.
8. **Nested transactions are one transaction.** Both libraries let a transaction start inside a
   transaction and neither gives you a real savepoint boundary from it: the inner block's failure
   rolls back the outer one.

## Testing

1. **The layer above the database is tested with a fake repository**, no database at all. That is
   what the port in `persistence-architecture` is for, and it is where most of the tests belong.
2. **DAOs and queries are tested against a real in-memory database.** They are worth testing —
   an `@Query` that compiles can still return the wrong rows — and a fake DAO tests nothing about
   the SQL.
3. **Room: `Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java)`, on the JVM under
   Robolectric** (`ApplicationProvider.getApplicationContext()` supplies the `Context`). That is the
   default for a DAO test; an instrumented one adds an emulator for nothing the JVM cannot check,
   and is kept for a test that depends on the device's own SQLite build.
4. **`allowMainThreadQueries()` belongs to tests and only to tests.** In a test it removes the need
   for a dispatcher dance around a synchronous assertion. In production it disables the one guard
   that turns a main-thread query into a crash instead of an ANR.
5. **Close the database in teardown.** An in-memory Room database that is never closed leaks its
   executor into the next test, and the suite fails in an order-dependent way that reads as flake.
6. **SQLDelight: `JdbcSqliteDriver(JdbcSqliteDriver.IN_MEMORY)` and then
   `AppDatabase.Schema.create(driver)`.** That is a plain JVM test — no Android, no Robolectric, no
   emulator — because creating the schema is an explicit call rather than a framework's job.
7. **On KMP, put the query tests in the source set that can run them.** A `commonTest` DAO test
   needs a driver on every target it compiles for; a `jvmTest` one needs only the JVM driver, and
   is usually where the SQL is worth checking.
8. **Test the mapping separately, as a pure function.** Entity in, domain out — no database, no
   coroutine, no framework (`arch-clean`).
9. **Migration tests are a different suite** with fixture databases at old versions:
   `persistence-migrations`.

## Migrations

Everything about changing a schema that has already shipped — Room's `exportSchema`, `Migration`
objects and `@AutoMigration` with its `@DeleteColumn`/`@RenameTable` specs, SQLDelight's numbered
`.sqm` files and their verification task, fixture-based tests at each old version, and the
progressive chain a user two releases behind will walk — is `persistence-migrations`.

Two things belong here, because they are decided while the database is being written:

- **Export the schema from the first version.** Room writes the JSON only when the plugin's
  `schemaDirectory` is configured, and the JSON for a version you did not export cannot be
  reconstructed once that version is on users' devices.
- **`fallbackToDestructiveMigration()` is a development convenience and nothing else.** In a release
  build it deletes the user's data on the first version bump that has no migration — silently, with
  no error, on their device and not yours.

## Common Mistakes

1. **`allowMainThreadQueries()` in production.** It exists to make tests simpler and is reached for
   to make a compile error go away. What it removes is the check that turns a main-thread query
   into an immediate crash in development; what it leaves is an ANR on the users with the most
   rows — the ones who use the app the most.
2. **`fallbackToDestructiveMigration()` in a release build.** The next version bump without a
   migration wipes the database: the user's offline drafts, their queued writes, their local
   history, gone with no message. Write the migration, or `persistence-migrations` explains the
   auto-migration that writes it for you.
3. **The entity used as the UI model.** `OrderEntity` reaches the composable, so the screen now
   depends on the column layout: renaming a column is a UI change, a nullable column becomes a `?`
   in every render path, and within a month the entity has a `displayTotal` field the database
   stores. Map at the repository (`arch-clean`).
4. **`exportSchema = false`, or the plugin's `schemaDirectory` never configured.** It silences a
   build warning and removes the input every auto-migration and every migration test needs. It is
   discovered exactly when it cannot be fixed.
5. **A `@Relation` read with no `@Transaction`.** Room runs the parent query and the child query
   separately; a write landing between them yields a parent holding another parent's children, in a
   bug that reproduces only under load.
6. **`OnConflictStrategy.REPLACE` used as "update".** It deletes the row and inserts a new one, so
   cascading children vanish and an autogenerated id changes. `@Upsert` is what the code meant.
7. **A database instance per call site.** `Room.databaseBuilder(...)` or `AppDatabase(driver)` in a
   repository constructor gives every consumer its own connection pool, its own cache and its own
   view of an open transaction. One instance, from the composition root (`di-hilt`, `di-koin`).
8. **`executeAsList()` on the main thread**, or `mapToList(Dispatchers.Main)`. SQLDelight runs the
   query wherever it is called and says nothing about it; Room's own guard does not exist here, so
   the discipline has to.
9. **Both libraries in one build.** A shared module on SQLDelight and an app module on Room means
   two schemas, two migration mechanisms and two answers to "where is this table". Pick one, write
   it down, and treat the second arrival as a dependency to remove.
