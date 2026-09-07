---
name: persistence-architecture
description: "Use when designing local storage in a Kotlin client or the persistence boundary of a server — the Repository as the only boundary, source-of-truth policy (database-first vs network-first), cache policy, threading with suspend and Flow, DataStore vs SharedPreferences vs files, KMP storage options, encryption at rest. Engine choice lives in persistence-room-sqldelight (client) and persistence-jvm-orm (server)."
---

# Persistence Architecture

Where a project's data actually lives, which copy is allowed to be believed when two of them
disagree, and how little of the storage the rest of the app is permitted to see. That is one
boundary — the repository — plus one source-of-truth policy per aggregate, chosen by a single
question about offline. Which engine sits under the boundary is `persistence-room-sqldelight` on a
client and `persistence-jvm-orm` on a server; every rule below is the same on both answers.

> **Related skills:**
> - `persistence-room-sqldelight` — the client engine decision, and the entity/DAO or `.sq` shapes this boundary hides
> - `persistence-jvm-orm` — the same decision on a JVM server, and the transaction boundary a repository sits inside there
> - `persistence-migrations` — changing a shipped schema without losing the rows already on the user's disk
> - `arch-clean` — the model families and the repository port this skill assumes rather than restates
> - `net-architecture` — the remote half of every policy below, and the HTTP cache that is not one of them
> - `concurrency-coroutines` — dispatcher per layer, and the scope that owns a write outliving its screen
> - `reactive-flow` — the sharing policy over a database `Flow`, and what each `started` value costs
> - `pkg-kmp-source-sets` — where a `commonMain` storage API is declared and its per-target halves live
> - `architecture-choice` — the compass that names this skill on every stack that keeps data past a process

## When to Use

- A feature is about to write its first row and nobody has said what the app shows with the radio off
- User asks "database or just cache the response", "why does the list flash the old data", "where do
  I put the token", "DataStore or SharedPreferences", "how do I store this on KMP", "should the
  database be encrypted"
- Review finds a `@Entity` in a ViewModel, a `Cursor` above `:data`, a `SharedPreferences` holding a
  refresh token, or a repository that calls the API on every collection of a `Flow`
- The symptom is a screen that shows a spinner on every visit despite having the rows already, a
  write that is lost when the app is killed, or two screens disagreeing about the same record

Not for picking Room against SQLDelight or writing either (`persistence-room-sqldelight`), not for
the server's ORM (`persistence-jvm-orm`), not for changing a schema that has shipped
(`persistence-migrations`), and not for HTTP freshness and `ETag` handling (`net-architecture`).

## Repository Boundary

```
ViewModel / use case        domain types only
        |
Repository                  source-of-truth policy, mapping, dispatcher switch, failure mapping
        |            \
   local source        remote source          both internal to :data
        |                    |
  Room / SQLDelight      OrdersApi            (JPA / Exposed / jOOQ on a server)
```

```kotlin
// :domain — the port. Nothing here can tell a database from a network call.
interface OrderRepository {
    fun observe(customer: CustomerId): Flow<List<Order>>
    suspend fun refresh(customer: CustomerId): Result<Unit>
    suspend fun place(draft: OrderDraft): Result<Order>
}
```

1. **The repository is the only boundary, and it is total.** No `@Entity`, no `Dao`, no
   `SqlDriver`, no `.sq`-generated `Queries` or data class, no `Cursor`, no JPA `EntityManager`,
   `@Entity` or managed instance, and no `SharedPreferences` handle appears in a signature above
   `:data`. One leak is enough: the ViewModel that accepts a Room entity has taken a dependency on
   the schema, and the next column rename is a UI change.
2. **What crosses is a domain value.** `arch-clean` owns the three model families and the mapping
   rule; this skill only insists that the *entity* family stops here, exactly as the DTO family
   does, and for the same reason — an entity is shaped by the schema, a domain model by the rules.
3. **One repository per aggregate, and the port says what while the implementation decides where**
   — both are `arch-clean`'s (`## Repositories`). The delta this skill adds is *what* does the
   deciding: the source-of-truth policy below, picked once per aggregate, is the reason the local
   and remote sources can stay `internal`.
4. **A repository returns `Result` or throws a domain error, never a storage exception.**
   `SQLiteConstraintException`, `IOException` and `PersistenceException` are engine facts;
   `error-architecture` names what they become.
5. **Fakes are the point.** The layer above is tested against an in-memory implementation of the
   port with no database at all; the real implementation gets its own integration test
   (`persistence-room-sqldelight`).

## Source of Truth

One policy per aggregate, written down, chosen by one question: **must this work offline?**

| Policy | Take when | Read path | Write path | With no network |
|---|---|---|---|---|
| database-first with sync | the feature has to work offline — a train, a lift, a bad hotel — or the user's own data must never be lost to a failed request | the database `Flow`, always; a response never reaches the UI directly | into the database first, then queued for the server | everything renders and everything writes; the queue drains later |
| network-first with cache | the app is online almost always, and freshness matters more than availability | the API, with the response written through to the cache | straight to the API; the cache is updated from the response | the last cached copy, rendered with an explicit staleness marker |
| no cache | the data is ephemeral, enormous, or must not be on disk at all — search results, a live price, a one-shot token | the API only | the API only | an error state; there is nothing to show and that is correct |

1. **Database-first means the database is the only read path.** The refresh writes rows; the UI
   collects the `Flow` and re-renders because the rows changed. A repository that returns the
   network response *and* writes it has two sources of truth and will show them in a different
   order on a slow connection.
2. **Name the conflict policy, per aggregate, before the first sync ships.** Last-write-wins by
   server timestamp, client-wins for fields the user typed, or a merge with a version token —
   pick one and write it in the project guidance file. "We will handle conflicts later" resolves
   itself as "whichever request finished last", which is a policy nobody chose.
3. **A local write needs a state, not just a row.** `pending`, `syncing`, `failed` on the entity (or
   a separate outbox table) is what lets the UI show a queued item, retry the failures and stop
   retrying the request the server rejected as invalid.
4. **The sync runs in an application scope**, not the one that started it: a write queued as the
   user leaves the screen must survive the ViewModel (`concurrency-coroutines`). On Android that
   often means `WorkManager` for the retry-across-process-death half.
5. **Network-first still owes the user a marker.** Cached rows served after a failed fetch and cached
   rows that are fresh look identical; if the screen cannot say "as of 10 minutes ago", the user
   reads stale data as current and reports it as a bug in the server.
6. **Staleness is a domain decision with a number.** This list is good for five minutes, this
   profile until the user edits it. Written as a constant next to the policy that reads it, not as
   a bare `300_000` compared against a timestamp inside a ViewModel.
7. **The HTTP cache is not any of these three rows.** It answers "is this URL's response still fresh
   according to the server" and it is `net-architecture`'s; none of it survives as domain rows you
   can query, sort or show offline.
8. **Mixing policies across one app is normal, mixing them for one aggregate is not.** Orders
   database-first and the currency list network-first is a design; orders both ways is a race.

```kotlin
// :data — database-first. The Flow is the whole read path; refresh only writes.
// DataError is a sealed Throwable family (`error-architecture`): kotlin.Result carries nothing else.
internal class OfflineFirstOrderRepository(
    private val dao: OrderDao,
    private val api: OrdersApi,
    private val io: CoroutineDispatcher,
) : OrderRepository {

    override fun observe(customer: CustomerId): Flow<List<Order>> =
        dao.observeByCustomer(customer.value).map { rows -> rows.map(OrderEntity::toDomain) }

    override suspend fun refresh(customer: CustomerId): Result<Unit> = withContext(io) {
        try {
            dao.upsertAll(api.orders(customer.value).items.map(OrderDto::toEntity))
            Result.success(Unit)
        } catch (e: CancellationException) {
            throw e                                  // never a failure: the screen left
        } catch (e: IOException) {
            Result.failure(DataError.Unreachable(e)) // the rows on disk are still valid
        }
    }
}
```

## Threading

1. **The storage API is `suspend` and `Flow`, and nothing else crosses the boundary.** Room and
   SQLDelight both offer that shape; a blocking call above `:data` is a choice, not a constraint.
2. **`Dispatchers.IO` is a `:data` word.** The `withContext(Dispatchers.IO)` goes in the repository
   or its local source — never in a use case (`arch-clean`, `## Use Cases`) and never in
   `commonMain` domain code. A ViewModel may *hold* an injected dispatcher, which is how
   `arch-mvvm` makes its own coroutines testable; what it must not do is wrap a repository call in
   a `withContext`, because that is it being told which layer blocks (`concurrency-coroutines`).
3. **Inject the dispatcher, do not name it.** A constructor parameter defaulting to `Dispatchers.IO`
   is replaced by a test dispatcher in one line; a hard-coded `Dispatchers.IO` inside the method
   makes every repository test depend on real thread scheduling.
4. **Room already moved off your thread.** A `suspend` DAO function runs on Room's own query
   executor and a `Flow` DAO function emits on it, so wrapping a DAO call in `withContext` buys
   nothing. The switch is for what *surrounds* it — file work, serialization, a JSON parse, the
   mapping of ten thousand rows.
5. **SQLDelight runs where you call it.** The generated `executeAsList()` is blocking and runs on
   the caller's thread; `asFlow().mapToList(context)` takes the dispatcher as an argument. On
   SQLDelight the `withContext` is not optional, and on `Dispatchers.Main` it is an ANR.
6. **Never block to read.** `runBlocking` around a query on the main thread is the same freeze
   whichever engine is under it, and it is the fix people reach for when a port leaked a
   non-suspending signature.
7. **One `Flow` per query, collected once per screen.** Two collectors on the same repository `Flow`
   run the query twice unless something shares it; `stateIn` with an explicit `started` policy is
   `reactive-flow`'s subject, and the choice matters most exactly here, where the upstream is a
   database cursor that stays open.
8. **On a JVM server the layer is the same and the dispatcher question differs** — a blocking JDBC
   call under virtual threads is no longer the problem it was, and `persistence-jvm-orm` owns the
   transaction boundary that comes with it.

## Small Data

| Data | Take | Never |
|---|---|---|
| flags, the last selected tab, a counter, an opt-in | `DataStore<Preferences>` | `SharedPreferences` in new code |
| a typed settings object with a schema | Proto DataStore, or `DataStore<T>` over a `kotlinx.serialization` serializer | a JSON string inside a preference key |
| tokens, passwords, encryption keys, anything a leak names in a headline | Keystore-backed encryption (below) | any preference store, plain or "encrypted-by-name" |
| user-owned documents, media, exports, anything measured in megabytes | files, with the path and metadata as a database row | a BLOB column, a preference, a cache directory you never clear |
| rows you query, sort, page or join | a database (`persistence-room-sqldelight`) | a serialized list in one preference key |

1. **DataStore over `SharedPreferences` in new code, for three reasons that are all bugs.**
   `SharedPreferences` reads are synchronous — the first one blocks on disk I/O, on whatever thread
   asked, main included. `apply()` is asynchronous with no result, so a write that failed is a write
   you never hear about, and it participates in the shutdown path in ways that lose data. DataStore
   is `Flow`-based, transactional, and reports failures as exceptions on the flow.
2. **`Preferences` for flat keys, `Proto` for a shape.** Preferences DataStore is typed keys over a
   map with no schema; Proto DataStore (or `DataStore<T>` with a serializer you write) gives one
   typed object, a default instance, and a migration path when a field changes meaning.
3. **A migration from `SharedPreferences` exists** — `SharedPreferencesMigration` — and it runs
   once, on first read. Ship it rather than reading both stores forever.
4. **Never a secret in either.** `SharedPreferences` and DataStore are plain files in the app's data
   directory: readable on a rooted device, in a backup, and in whatever the OEM's cloud sync
   captured.
5. **`EncryptedSharedPreferences` is not the answer any more.** Jetpack Security's crypto library
   was deprecated in 2024 and stalled at `1.1.0-alpha`; do not add it to a new build and do not
   treat it as maintained in an old one.
6. **What replaces it is a Keystore-backed key plus an AEAD cipher — yours or a maintained
   wrapper's.** Generate an AES key in the Android Keystore (`AndroidKeyStore`, hardware-backed
   where the device offers it), encrypt with AES-GCM, store the ciphertext and IV in the ordinary
   store. Write it once, behind a `SecretStore` interface, or adopt a library the team has actually
   checked is alive — but check, rather than taking a name from memory.
7. **The best secret is the one you do not store.** A short-lived access token kept in memory and
   re-fetched from a refresh token the OS protects beats a long-lived credential encrypted well.
8. **Files are a store with rules.** Keep them out of the database, keep their *metadata* in it, and
   pick the directory deliberately: cache directories can be reclaimed by the OS at any moment,
   which is correct for a thumbnail and a data-loss bug for a draft.

## On KMP

| Need | Take |
|---|---|
| a relational database in `commonMain` | SQLDelight, or Room 2.7+ where its target list is enough (`persistence-room-sqldelight`) |
| key-value settings | `com.russhwolf:multiplatform-settings`, over `NSUserDefaults`, `SharedPreferences`/DataStore and the JVM `Preferences` API per target |
| files, streams, paths | Okio — `okio.FileSystem`, `okio.Path` — the mature option, with `kotlinx-io` as the newer Kotlin-native alternative |

1. **Declare the storage API in `commonMain` and the driver or factory per target.** The database
   type, the DAO or `Queries`, the repository and the mapping are common; only the thing that opens
   a file handle is `expect`/`actual` (`pkg-kmp-source-sets`).
2. **A `commonMain` repository must not name a platform store.** The moment `SharedPreferences`
   appears in shared code the module has stopped being shared, and the compiler will say so on the
   second target rather than the first.
3. **Neither platform has a "just write a file wherever".** On iOS the path comes from the OS's own
   directory API; on Android it is `filesDir` for what must survive, `cacheDir` for what the system
   may reclaim without asking, and `getExternalFilesDir` for what the user or another app may see.
   Whether the directory is backed up is a privacy decision either way — on Android, exclude a
   database holding anything sensitive from Auto Backup through `dataExtractionRules`. Decide once,
   in the `actual`.

## Encryption

At-rest encryption is a deployment decision with a real cost: a native library in every target, a
key that has to live somewhere safer than the database, and a version matrix that moves.

1. **SQLCipher is the answer for a SQLite-backed store on Android.** `net.zetetic:sqlcipher-android`
   is the maintained artifact (the older `android-database-sqlcipher` is not); it supplies a
   `SupportOpenHelperFactory` that Room accepts via `openHelperFactory()` on the builder, which is
   the whole integration on the Room side.
2. **SQLDelight takes it through the driver.** `AndroidSqliteDriver` accepts a factory, so the same
   SQLCipher `SupportOpenHelperFactory` goes there; on iOS the equivalent is a SQLCipher build
   behind `NativeSqliteDriver`, which means a pod or a native dependency rather than a Gradle line.
3. **All of this is version-sensitive.** Artifact coordinates, the constructor a driver exposes and
   the minimum SQLite version have all changed inside the last two releases of both projects: read
   the current documentation before writing the setup, and pin the version in the catalog.
4. **The passphrase is the hard half.** A key compiled into the APK is not a key; derive it from a
   Keystore-held secret (or from a user credential where the threat model asks for it), and decide
   in advance what happens when the key is lost — for a cache, drop the database; for user data,
   nothing good, which is a reason to sync.
5. **Encrypt because a threat model asked.** Health data, financial records, messages, a device
   fleet under a compliance regime — yes. A list of read articles on a locked phone — the whole
   volume is already encrypted by the OS, and SQLCipher buys a slower database and a new way to
   fail on upgrade.
6. **Per-column encryption is the cheaper middle.** Two sensitive fields encrypted at the mapping
   boundary keep the schema queryable and cost no native library; you lose the ability to index or
   search those two fields, which is usually acceptable and always worth stating.

## On the Server

The boundary is identical and the mechanics are not: a repository over JPA, Exposed, jOOQ or Spring
Data JDBC, with the transaction — not the query — as the unit that matters, and the schema owned by
a migration tool rather than by the code that reads it.

- Engine choice, Kotlin-with-JPA pitfalls, N+1, connection pools and Testcontainers:
  `persistence-jvm-orm`.
- Schema change, expand/contract and zero-downtime deploys: `persistence-migrations`.
- Where the transaction boundary sits relative to the layers: `arch-layered`, `arch-hexagonal`.

The one rule that travels unchanged is the first one in this skill: a managed entity does not leave
the layer that loaded it — on a server it cannot, because outside its session the lazy associations
throw and the change tracking is gone.

## Common Mistakes

1. **A persistence entity used as the UI model.** `arch-clean` mistake 3 states it and the mapping
   rule behind it; what this skill adds is that the entity family leaks the *schema* rather than the
   wire, so the price is paid on every column rename. The engine-specific spelling — a Room
   `@Entity`, a `.sq`-generated row — is `persistence-room-sqldelight` mistake 3.
2. **Two sources of truth for one aggregate.** The repository returns the network response *and*
   writes it to the database that the screen also observes; the list renders twice, in an order
   that depends on the connection, and the "flash of old data" bug is unreproducible on wifi.
3. **A token, a password or a key in `SharedPreferences` or DataStore.** Both are plain files in the
   app's data directory. `EncryptedSharedPreferences` is not the fix — it is deprecated — and a
   Base64 encoding is not encryption.
4. **`Dispatchers.IO` in the ViewModel.** The switch is in the wrong layer, the port has leaked the
   fact that it blocks, and the day the repository becomes a network call the `withContext` stays
   behind as a lie about where the work happens.
5. **`runBlocking` around a query.** On the main thread it is a freeze the profiler will show as
   "storage is slow"; it appears whenever a non-suspending signature escaped `:data` and the caller
   had no other way to satisfy it.
6. **Treating the HTTP cache as the offline story.** It caches responses by URL for as long as the
   server permits and hands back nothing you can query, sort or show in a list; an app that must
   work on a train needs rows on disk (`net-architecture`).
7. **No conflict policy.** Two devices, one record, and whichever request arrived last wins — with
   no timestamp, no version and no way for the user to see that their edit was overwritten. Choose
   before the second device exists.
8. **A large blob in a column.** Images and documents belong in files with their paths in the
   database; a database that carries them is slow to query, expensive to back up, and now needs a
   migration strategy for bytes that never change.
9. **A database instance per call site.** `Room.databaseBuilder(...).build()` or
   `AppDatabase(driver)` inside a repository constructor gives every consumer its own connection,
   its own cache and its own view of an open transaction. Both engines open the file lazily on
   first use, which is correct and not the bug; what has to be a singleton is the instance, built
   once in the composition root.
