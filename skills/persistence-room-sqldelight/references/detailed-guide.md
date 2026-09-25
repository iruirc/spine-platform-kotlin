# persistence-room-sqldelight — detailed guide

## Contents

- The Domain Side
- Room — Entity and DAO
- Room — Database and Wiring
- Room — Repository and Flow Queries
- Room — Transactions
- Room — In-Memory Test
- SQLDelight — The .sq File
- SQLDelight — Gradle and Drivers
- SQLDelight — Repository and Flow Queries
- SQLDelight — Transactions
- SQLDelight — In-Memory Test
- Room on KMP

## The Domain Side

The domain side is the same in both halves and belongs to no engine: an `Order` with an `Instant`,
an `OrderStatus` and a list of `OrderLine`, behind one port.

<!-- compile: android -->
```kotlin
// :domain — nothing below this block appears in it.
interface OrderRepository {
    fun observe(customer: CustomerId): Flow<List<Order>>
    suspend fun byId(id: OrderId): Order?
    suspend fun replace(order: Order)
}
```

Dependencies are version-catalog aliases, each artifact named where it is first used.

## Room — Entity and DAO

<!-- compile: android -->
```kotlin
@Entity(
    tableName = "orders",
    indices = [Index("customer_id"), Index("sync_state")],
)
data class OrderEntity(
    @PrimaryKey val id: String,
    @ColumnInfo(name = "customer_id") val customerId: String,
    @ColumnInfo(name = "placed_at") val placedAt: Long,
    val status: String,
    @ColumnInfo(name = "sync_state") val syncState: String,
)

@Entity(
    tableName = "order_lines",
    foreignKeys = [ForeignKey(
        entity = OrderEntity::class, parentColumns = ["id"], childColumns = ["order_id"],
        onDelete = ForeignKey.CASCADE,
    )],
    indices = [Index("order_id")],
)
data class OrderLineEntity(
    @PrimaryKey val id: String,
    @ColumnInfo(name = "order_id") val orderId: String,
    val sku: String,
    val quantity: Int,
    @ColumnInfo(name = "unit_price_minor") val unitPriceMinor: Long,
)
```

The parent-and-children read is one declared shape, `@Transaction` because Room runs two statements:

<!-- compile: android -->
```kotlin
data class OrderWithLines(
    @Embedded val order: OrderEntity,
    @Relation(parentColumn = "id", entityColumn = "order_id")
    val lines: List<OrderLineEntity>,
)

@Dao
interface OrderDao {

    @Transaction
    @Query("SELECT * FROM orders WHERE customer_id = :customerId ORDER BY placed_at DESC")
    fun observeByCustomer(customerId: String): Flow<List<OrderWithLines>>

    @Transaction
    @Query("SELECT * FROM orders WHERE id = :id")
    suspend fun byId(id: String): OrderWithLines?

    @Query("SELECT * FROM orders WHERE sync_state = :state")
    suspend fun bySyncState(state: String): List<OrderEntity>

    @Upsert suspend fun upsertOrder(order: OrderEntity)
    @Upsert suspend fun upsertLines(lines: List<OrderLineEntity>)

    @Query("DELETE FROM order_lines WHERE order_id = :orderId")
    suspend fun deleteLines(orderId: String)
}
```

- `status` and `sync_state` are `String` columns because SQLite has no enum; the mapper below is
  where they become one, and a `TypeConverter` only moves that same code into an annotation.

## Room — Database and Wiring

<!-- compile: android -->
```kotlin
@Database(
    entities = [OrderEntity::class, OrderLineEntity::class],
    version = 2,                 // MIGRATION_1_2 below carries the devices still on 1
    exportSchema = true,
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun orderDao(): OrderDao
}
```

`build.gradle.kts` — KSP, the Room plugin, and the directory the exported schema JSON lands in:

```kotlin
plugins {
    alias(libs.plugins.ksp)              // com.google.devtools.ksp
    alias(libs.plugins.androidx.room)    // androidx.room
}

room { schemaDirectory("$projectDir/schemas") }

dependencies {
    implementation(libs.androidx.room.runtime)  // androidx.room:room-runtime, withTransaction included
    ksp(libs.androidx.room.compiler)            // androidx.room:room-compiler
}
```

<!-- compile: android -->
```kotlin
// Composition root, one instance per process — a Hilt module here, a Koin `single` elsewhere.
@Module
@InstallIn(SingletonComponent::class)
object DatabaseModule {
    @Provides
    @Singleton
    fun database(@ApplicationContext context: Context): AppDatabase =
        Room.databaseBuilder(context, AppDatabase::class.java, "app.db")
            .addMigrations(MIGRATION_1_2)
            .build()
}
```

- `exportSchema = true` plus `schemaDirectory` is what writes `schemas/<db>/1.json`. Commit it: an
  auto-migration is computed from the difference between two of those files.
- No `fallbackToDestructiveMigration(…)` in this builder: it belongs to a debug variant or nowhere.

## Room — Repository and Flow Queries

The mapper and the repository are the whole of what the layer above sees; `toEntity` is its mirror:

```kotlin
internal fun OrderWithLines.toDomain() = Order(
    id = OrderId(order.id),
    customer = CustomerId(order.customerId),
    placedAt = Instant.fromEpochMilliseconds(order.placedAt),
    status = OrderStatus.valueOf(order.status),
    lines = lines.map { OrderLine(it.sku, it.quantity, it.unitPriceMinor) },
)
```

<!-- compile: android -->
```kotlin
internal class RoomOrderRepository(
    private val db: AppDatabase,
    private val dao: OrderDao,
) : OrderRepository {

    override fun observe(customer: CustomerId): Flow<List<Order>> =
        dao.observeByCustomer(customer.value).map { rows -> rows.map(OrderWithLines::toDomain) }

    override suspend fun byId(id: OrderId): Order? = dao.byId(id.value)?.toDomain()

    override suspend fun replace(order: Order) = db.withTransaction {
        dao.upsertOrder(order.toEntity(syncState = "PENDING"))
        dao.deleteLines(order.id.value)
        dao.upsertLines(order.lines.map { it.toEntity(order.id) })
    }
}
```

- No dispatcher: Room is on the "nothing to switch" row of
  `concurrency-coroutines` → "Per-Layer Dispatchers".

## Room — Transactions

```kotlin
// Inside one DAO: a default body calling other methods of the same DAO, wrapped by Room.
@Dao
interface OrderDao {

    @Transaction
    suspend fun replaceLines(orderId: String, lines: List<OrderLineEntity>) {
        deleteLines(orderId)
        upsertLines(lines)
    }
}
```

```kotlin
// Across DAOs, or with logic between the writes: withTransaction, from room-runtime.
suspend fun drainOutbox(db: AppDatabase, api: OrdersApi) {
    for (entity in db.orderDao().bySyncState("PENDING")) {
        api.place(entity.toDto())                     // outside the transaction, on purpose
        db.withTransaction {
            db.orderDao().upsertOrder(entity.copy(syncState = "SYNCED"))
            db.outboxDao().delete(entity.id)          // a second DAO on the same @Database
        }
    }
}
```

- The network call is deliberately outside the block. A transaction held across an HTTP request
  blocks every other write for as long as the server is slow.
- `runBlocking` inside `withTransaction` deadlocks: the block already occupies the transaction
  thread the nested call would need.

## Room — In-Memory Test

```kotlin
// A JVM test: Robolectric supplies the Context the in-memory builder wants.
@RunWith(RobolectricTestRunner::class)
class OrderDaoTest {

    private lateinit var db: AppDatabase
    private lateinit var dao: OrderDao

    @Before fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        db = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java)
            .allowMainThreadQueries()           // tests only: never in production code
            .build()
        dao = db.orderDao()
    }

    @After fun tearDown() = db.close()

    @Test fun observeByCustomer_lineAdded_reEmits() = runTest {
        dao.upsertOrder(orderEntity(id = "o-1", customerId = "c-1"))

        dao.observeByCustomer("c-1").test {
            assertEquals(0, awaitItem().single().lines.size)
            dao.upsertLines(listOf(lineEntity(id = "l-1", orderId = "o-1")))
            assertEquals(1, awaitItem().single().lines.size)
            cancelAndIgnoreRemainingEvents()
        }
    }
}
```

- `allowMainThreadQueries()` is here so a synchronous assertion needs no dispatcher choreography.
  It is the single legitimate use of that call, and it never leaves a test source set.
- `close()` in teardown: an in-memory database that is never closed leaks its executor into the
  next test and the suite starts failing in an order-dependent way.

## SQLDelight — The .sq File

`src/commonMain/sqldelight/com/example/db/Order.sq` — that directory must match `packageName`:

```sql
import com.example.orders.OrderStatus;
import kotlin.Int;
import kotlin.time.Instant;

CREATE TABLE orderRecord (
  id            TEXT    NOT NULL PRIMARY KEY,
  customerId    TEXT    NOT NULL,
  placedAt      INTEGER AS Instant NOT NULL,
  status        TEXT    AS OrderStatus NOT NULL,
  syncState     TEXT    NOT NULL
);

CREATE TABLE orderLineRecord (
  id            TEXT    NOT NULL PRIMARY KEY,
  orderId       TEXT    NOT NULL REFERENCES orderRecord(id) ON DELETE CASCADE,
  sku           TEXT    NOT NULL,
  quantity      INTEGER AS Int NOT NULL,
  unitPriceMinor INTEGER NOT NULL
);

CREATE INDEX orderRecord_customer ON orderRecord(customerId);
CREATE INDEX orderLineRecord_order ON orderLineRecord(orderId);

selectByCustomer:
SELECT * FROM orderRecord WHERE customerId = ? ORDER BY placedAt DESC;

selectById:
SELECT * FROM orderRecord WHERE id = ?;

selectLinesFor:
SELECT * FROM orderLineRecord WHERE orderId IN ?;

upsertOrder:
INSERT INTO orderRecord(id, customerId, placedAt, status, syncState) VALUES (?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  customerId = excluded.customerId, placedAt = excluded.placedAt,
  status = excluded.status, syncState = excluded.syncState;

deleteLinesFor:
DELETE FROM orderLineRecord WHERE orderId = ?;

insertLine:
INSERT INTO orderLineRecord VALUES ?;
```

- Each label generates one function on `OrderQueries`, typed against the schema: `selectByCustomer`
  returns `Query<OrderRecord>`, `insertLine` takes a whole `OrderLineRecord` because its `VALUES ?`
  binds the row, and a `SELECT` of two columns would generate a data class for exactly those two.
- `AS Instant`, `AS OrderStatus` and `AS Int` declare a column's Kotlin type; SQLDelight then wants
  a `ColumnAdapter` for each, supplied where the database is constructed — the one place a timestamp
  or an enum is parsed. `Int` is imported like any other type: without `import kotlin.Int;` the
  generated code fails with "Unresolved reference 'Int'".
- `ON CONFLICT … DO UPDATE` is the upsert; `INSERT OR REPLACE` would delete first and take the
  cascading lines with it — Room's `OnConflictStrategy.REPLACE` trap in SQL. The cascade itself needs
  `PRAGMA foreign_keys = ON`, which SQLite leaves off by default and no driver turns on for you:
  each `actual` below does it.

## SQLDelight — Gradle and Drivers

```kotlin
plugins { alias(libs.plugins.sqldelight) }        // app.cash.sqldelight

sqldelight {
    databases {
        create("AppDatabase") {
            packageName.set("com.example.db")
            // ON CONFLICT ... DO UPDATE is SQLite 3.24; SQLDelight 2.x compiles against 3.18.
            dialect("app.cash.sqldelight:sqlite-3-24-dialect:<version>")
        }
    }
}

kotlin.sourceSets {
    commonMain.dependencies {
        implementation(libs.sqldelight.runtime)      // app.cash.sqldelight:runtime
        implementation(libs.sqldelight.coroutines)   // app.cash.sqldelight:coroutines-extensions
        implementation(libs.sqldelight.primitive.adapters) // app.cash.sqldelight:primitive-adapters
    }
    androidMain.dependencies { implementation(libs.sqldelight.android) }  // :android-driver
    iosMain.dependencies { implementation(libs.sqldelight.native) }       // :native-driver
    jvmMain.dependencies { implementation(libs.sqldelight.sqlite) }       // :sqlite-driver
}
```

The database is `commonMain`, only the driver per target; the declared adapters are supplied once:

```kotlin
// commonMain
expect class DriverFactory { fun create(): SqlDriver }

val instantAdapter = object : ColumnAdapter<Instant, Long> {
    override fun decode(databaseValue: Long) = Instant.fromEpochMilliseconds(databaseValue)
    override fun encode(value: Instant) = value.toEpochMilliseconds()
}

// Named arguments: the generated adapter parameters are sorted by name, not in .sq order.
fun appDatabase(factory: DriverFactory) = AppDatabase(
    driver = factory.create(),
    orderRecordAdapter = OrderRecord.Adapter(instantAdapter, EnumColumnAdapter()),
    orderLineRecordAdapter = OrderLineRecord.Adapter(IntColumnAdapter),
)
```

```kotlin
// androidMain — foreign keys are off by default in SQLite; the callback turns them on
actual class DriverFactory(private val context: Context) {
    actual fun create(): SqlDriver = AndroidSqliteDriver(
        schema = AppDatabase.Schema, context = context, name = "app.db",
        callback = object : AndroidSqliteDriver.Callback(AppDatabase.Schema) {
            override fun onOpen(db: SupportSQLiteDatabase) =
                db.setForeignKeyConstraintsEnabled(true)
        },
    )
}

// iosMain
actual class DriverFactory {
    actual fun create(): SqlDriver = NativeSqliteDriver(
        schema = AppDatabase.Schema, name = "app.db",
        onConfiguration = { it.copy(extendedConfig = DatabaseConfiguration.Extended(foreignKeyConstraints = true)) },
    )
}

// jvmMain
actual class DriverFactory(private val path: String) {
    actual fun create(): SqlDriver = JdbcSqliteDriver(
        "jdbc:sqlite:$path", Properties().apply { put("foreign_keys", "true") }, AppDatabase.Schema,
    )
}
```

- All three create and migrate the schema themselves from the `AppDatabase.Schema` they are handed
  — the JDBC one only when it is passed to the constructor, which is why the desktop `actual` names
  it there rather than calling `Schema.create` separately.
- The dialect above is a compile-time decision; the runtime SQLite is the platform's. Android at API
  30 ships 3.28, comfortably past upsert's 3.24, but a lower `minSdk` reaches devices whose SQLite
  is older, and those need a bundled SQLite distribution or an insert-then-update fallback.
- A web target takes `WebWorkerDriver` from `app.cash.sqldelight:web-worker-driver`, pointed at a
  worker script; on Room it is Room 3's row of the Decision table in `SKILL.md`.

## SQLDelight — Repository and Flow Queries

```kotlin
internal class SqlDelightOrderRepository(
    private val db: AppDatabase,
    private val io: CoroutineDispatcher,
) : OrderRepository {

    private val queries = db.orderQueries

    override fun observe(customer: CustomerId): Flow<List<Order>> =
        queries.selectByCustomer(customer.value)
            .asFlow()
            .mapToList(io)                       // io, never Dispatchers.Main
            .map { records -> records.map { it.toDomain(linesFor(it.id)) } }
            .flowOn(io)

    override suspend fun byId(id: OrderId): Order? = withContext(io) {
        queries.selectById(id.value).executeAsOneOrNull()
            ?.let { it.toDomain(linesFor(it.id)) }
    }

    private fun linesFor(orderId: String): List<OrderLine> =
        queries.selectLinesFor(listOf(orderId)).executeAsList().map(OrderLineRecord::toDomain)
}
```

- The child fetch per parent is the N+1 this shape invites, and `executeAsList()` is blocking. For a
  list, select the page's lines in one `IN ?` query and group in Kotlin; for one screen, an extra
  query beats the join.

## SQLDelight — Transactions

```kotlin
override suspend fun replace(order: Order) = withContext(io) {
    db.transaction {
        queries.upsertOrder(
            id = order.id.value, customerId = order.customer.value,
            placedAt = order.placedAt, status = order.status, syncState = "PENDING",
        )
        queries.deleteLinesFor(order.id.value)
        order.lines.forEach { queries.insertLine(it.toRecord(order.id)) }  // domain -> row
        afterCommit { analytics.orderQueued(order.id) }   // only if the write actually landed
    }
}
```

- `transactionWithResult { }` is the same block when the unit of work produces a value, and
  `transaction { }` is not `suspend`: a suspending call cannot be written inside it, which is the
  library preventing a network round trip from being awaited with a write transaction open. The
  whole block goes inside `withContext(io)` instead.
- `rollback()` aborts explicitly; a thrown exception rolls back too. `afterRollback { }` is the
  mirror of `afterCommit { }` for compensating work.

## SQLDelight — In-Memory Test

```kotlin
class OrderQueriesTest {

    private lateinit var driver: SqlDriver
    private lateinit var db: AppDatabase

    @BeforeTest fun setUp() {
        driver = JdbcSqliteDriver(JdbcSqliteDriver.IN_MEMORY)
        AppDatabase.Schema.create(driver)
        db = AppDatabase(
            driver = driver,
            orderRecordAdapter = OrderRecord.Adapter(instantAdapter, EnumColumnAdapter()),
            orderLineRecordAdapter = OrderLineRecord.Adapter(IntColumnAdapter),
        )
    }

    @AfterTest fun tearDown() = driver.close()

    @Test fun selectByCustomer_matchingOrderInserted_reEmits() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        db.orderQueries.selectByCustomer("c-1").asFlow().mapToList(dispatcher).test {
            assertEquals(0, awaitItem().size)
            db.orderQueries.upsertOrder("o-1", "c-1", Instant.fromEpochMilliseconds(0), OrderStatus.PLACED, "SYNCED")
            assertEquals(1, awaitItem().size)
            cancelAndIgnoreRemainingEvents()
        }
    }
}
```

- A plain JVM test: no `Context`, no Robolectric, no emulator, because the schema is created by an
  explicit call rather than by a framework at open time.
- `JdbcSqliteDriver.IN_MEMORY` is the JDBC URL constant; the database dies with the driver, so
  `close()` in teardown is what makes each test independent.

## Room on KMP

Room 2.7+ in `commonMain`: the entities, DAOs and queries above move unchanged; the constructor and
the driver are new.

```kotlin
// commonMain
@Database(entities = [OrderEntity::class, OrderLineEntity::class], version = 1)
@ConstructedBy(AppDatabaseConstructor::class)
abstract class AppDatabase : RoomDatabase() {
    abstract fun orderDao(): OrderDao
}

// The actual is generated per target by the Room compiler.
@Suppress("NO_ACTUAL_FOR_EXPECT")
expect object AppDatabaseConstructor : RoomDatabaseConstructor<AppDatabase> {
    override fun initialize(): AppDatabase
}
```

```kotlin
// iosMain — a path from the platform, SQLite shipped with the app, an explicit query context
fun appDatabase(): AppDatabase =
    Room.databaseBuilder<AppDatabase>(name = "${documentsDirectory()}/app.db")
        .setDriver(BundledSQLiteDriver())          // androidx.sqlite:sqlite-bundled
        .setQueryCoroutineContext(Dispatchers.IO)  // no default outside Android
        .build()
```

- The build applies the `androidx.room` plugin once and `ksp(libs.androidx.room.compiler)` per
  target; `androidx.sqlite:sqlite-bundled` is the driver everywhere except Android.
- Room 2.x's target list is Android, iOS, JVM and native. A browser build is SQLDelight's
  `WebWorkerDriver`, or Room 3 (the Decision table in `SKILL.md`).
- Exported schemas and `Migration` objects work as on Android, and `androidx.room:room-testing` is
  published for the KMP targets from 2.7, so `MigrationTestHelper` is reachable from a
  multiplatform test — it takes the schema directory, the file name and a driver. Verify that
  signature, and the Paging integration's target list, against the 2.7 release notes
  (`persistence-migrations`).
