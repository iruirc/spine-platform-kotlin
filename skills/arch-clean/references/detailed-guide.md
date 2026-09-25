# arch-clean — detailed guide

## Contents

- Reading These Files
- Domain — Entity and Repository Port
- Domain — Use Cases
- Data — DTO and the Remote Source
- Data — Room Entity and the Local Source
- Data — Mappers
- Data — Repository Implementation
- Presentation — ViewModel
- Testing
- Gradle Wiring

## Reading These Files

The two Domain sections define the types every later section maps to and are worth reading first;
from there each section stands alone.

The header comment on each block is the module and path the file belongs to. That is not decoration:
in this architecture the path *is* the constraint, because the module a file sits in decides what it
is allowed to import.

Time types are `kotlin.time.Instant` and `kotlin.time.Clock`, stable since Kotlin 2.3;
`kotlinx-datetime` joins `:domain` only for calendar types such as `LocalDate`.

## Domain — Entity and Repository Port

The innermost module. The entire import list across the three files below is `kotlin.time.Instant`
and `kotlinx.coroutines.flow.Flow`.

<!-- compile: android -->
```kotlin
// :domain — com/acme/domain/orders/Order.kt
package com.acme.domain.orders

import kotlin.time.Instant

@JvmInline value class OrderId(val value: String)
@JvmInline value class CustomerId(val value: String)

@JvmInline
value class Money(val minor: Long) {
    operator fun plus(other: Money) = Money(minor + other.minor)
}

/** `Unknown` is not dead code: the server may ship a status this build has never heard of. */
enum class OrderStatus { Placed, Paid, Shipped, Cancelled, Archived, Unknown }

data class OrderLine(val sku: String, val quantity: Int, val amount: Money)

data class Order(
    val id: OrderId,
    val customer: CustomerId,
    val placedAt: Instant,
    val status: OrderStatus,
    val currency: String,
    val lines: List<OrderLine>,
) {
    val isArchived: Boolean get() = status == OrderStatus.Archived
    val total: Money get() = lines.fold(Money(0)) { sum, line -> sum + line.amount }
}
```

The failure type. It is an `Exception` subclass so it fits `kotlin.Result`'s failure slot, and it is
`sealed` so a `when` over it is exhaustive at every call site that cares:

<!-- compile: android -->
```kotlin
// :domain — com/acme/domain/orders/OrderError.kt
sealed class OrderError(message: String? = null, cause: Throwable? = null) :
    Exception(message, cause) {

    data object Offline : OrderError()
    data object NotFound : OrderError()
    data class Rejected(val reason: String) : OrderError(reason)
    data class Unexpected(val error: Throwable) : OrderError(cause = error)
}
```

The port. Domain vocabulary in the names, domain types in the signatures, and no hint of where the
data is or how it travels:

<!-- compile: android -->
```kotlin
// :domain — com/acme/domain/orders/OrderRepository.kt
import kotlinx.coroutines.flow.Flow

interface OrderRepository {
    /** Fresh if it can be, cached if it cannot. Expected failures arrive as `OrderError`. */
    suspend fun orders(customer: CustomerId): Result<List<Order>>

    /** The local store as source of truth; re-emits after every successful refresh. */
    fun observeOrders(customer: CustomerId): Flow<List<Order>>

    suspend fun refresh(customer: CustomerId): Result<Unit>

    suspend fun order(id: OrderId): Result<Order>

    suspend fun cancel(id: OrderId): Result<Order>
}
```

Note what is *not* here: no `page`, no `ifNoneMatch`, no `forceRefresh` flag. Paging and cache
validators are how the data layer honours `orders()`, not something the domain asks for. Adding one
of them here would put transport vocabulary in the module that is supposed to have none, and every
fake in every test would grow a parameter it ignores.

## Domain — Use Cases

The simple shape first: one collaborator, one public function, one rule.

<!-- compile: android -->
```kotlin
// :domain — com/acme/domain/orders/GetOrders.kt
class GetOrders(private val repo: OrderRepository) {
    suspend operator fun invoke(id: CustomerId): Result<List<Order>> =
        repo.orders(id).map { orders ->
            orders.filterNot(Order::isArchived).sortedByDescending(Order::placedAt)
        }
}
```

"Archived orders are not shown, newest first" is a rule and it now has exactly one home. Delete the
two lines inside `map` and this class becomes Mistake 1: a file that forwards a call.

The shape that pays for the whole layer — three collaborators, a policy, and not one line of it
reachable from a ViewModel test any other way:

`PaymentRepository` below is a second port in the same module, declared the same way — the use case
is where two of them meet, and that meeting is the reason this layer exists.

<!-- compile: android -->
```kotlin
// :domain — com/acme/domain/orders/CancelOrder.kt
import kotlin.time.Clock
import kotlin.time.Duration.Companion.hours

class CancelOrder(
    private val orders: OrderRepository,
    private val payments: PaymentRepository,
    private val clock: Clock,
) {
    suspend operator fun invoke(id: OrderId): Result<Order> {
        val order = orders.order(id).getOrElse { return Result.failure(it) }

        if (order.status == OrderStatus.Shipped) {
            return Result.failure(OrderError.Rejected("a shipped order is returned, not cancelled"))
        }
        if (clock.now() - order.placedAt > CANCELLATION_WINDOW) {
            return Result.failure(OrderError.Rejected("the cancellation window has closed"))
        }

        payments.refund(order.id, order.total).getOrElse { return Result.failure(it) }
        return orders.cancel(id)
    }

    private companion object { val CANCELLATION_WINDOW = 24.hours }
}
```

Three things this file demonstrates beyond the rule itself:

- **`Clock` is a constructor parameter**, so "the window has closed" is one line in a test rather
  than a sleep. A `Clock.System.now()` inline would make this class untestable in the one dimension
  it exists to guard.
- **`kotlin.Result` has no `flatMap`.** `getOrElse { return Result.failure(it) }` is the idiom for
  short-circuiting a chain of fallible steps; `fold` is the idiom when both branches produce a value.
  Reaching for Arrow's `Either` and `either { }` is a project-wide decision, not a per-use-case one
  (`error-architecture`).
- **The refund happens before the cancel**, and that ordering is a business decision sitting in the
  one place both a reviewer and a test can find it.

## Data — DTO and the Remote Source

The wire model. Every field is nullable and every name matches the payload, because the DTO's job is
to survive whatever the server actually sends — the shape the rules want is the mapper's problem:

<!-- compile: android -->
```kotlin
// :data — com/acme/data/orders/OrderDto.kt
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
internal data class OrderDto(
    val id: String? = null,
    @SerialName("customer_id") val customerId: String? = null,
    @SerialName("placed_at") val placedAt: String? = null,
    val status: String? = null,
    val currency: String? = null,
    val lines: List<OrderLineDto>? = null,
)

@Serializable
internal data class OrderLineDto(
    val sku: String? = null,
    val quantity: Int? = null,
    @SerialName("amount_minor") val amountMinor: Long? = null,
)
```

`internal` is doing real work: it makes leaking a DTO out of `:data` a compile error rather than a
review comment. Give every DTO, entity, DAO, API interface and mapper in this module the modifier.

Retrofit, on Android or any JVM client:

<!-- compile: android -->
```kotlin
// :data — com/acme/data/orders/OrderApi.kt
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.Path

internal interface OrderApi {
    @GET("customers/{id}/orders")
    suspend fun orders(
        @Path("id") customer: String,
        @retrofit2.http.Query("page") page: Int = 1,
    ): List<OrderDto>

    @GET("orders/{id}")
    suspend fun order(@Path("id") id: String): OrderDto

    @POST("orders/{id}/cancel")
    suspend fun cancel(@Path("id") id: String): OrderDto
}
```

The same source on the Ktor client, which is what KMP forces and what a server calling another
service usually already has (`net-http-clients`):

```kotlin
// :data — com/acme/data/orders/KtorOrderApi.kt
internal class KtorOrderApi(private val client: HttpClient) {
    suspend fun orders(customer: String, page: Int = 1): List<OrderDto> =
        client.get("customers/$customer/orders") { parameter("page", page) }.body()

    suspend fun order(id: String): OrderDto = client.get("orders/$id").body()

    suspend fun cancel(id: String): OrderDto = client.post("orders/$id/cancel").body()
}
```

`page` lives here and stops here. `OrderRepositoryImpl` walks the pages; `OrderRepository` never
learned that pages exist. Retry, auth headers and the interceptor or plugin order that carries them
are `net-architecture`.

## Data — Room Entity and the Local Source

The schema model. Flat, indexed, keyed, and shaped by what SQLite can store — `Instant` becomes a
`Long`, the enum becomes a `String`, and the nested lines become a second table:

<!-- compile: android -->
```kotlin
// :data — com/acme/data/orders/OrderEntity.kt
@Entity(tableName = "orders", indices = [Index("customer_id")])
internal data class OrderEntity(
    @PrimaryKey val id: String,
    @ColumnInfo(name = "customer_id") val customerId: String,
    @ColumnInfo(name = "placed_at") val placedAtMillis: Long,
    val status: String,
    val currency: String,
)

@Entity(
    tableName = "order_lines",
    primaryKeys = ["order_id", "sku"],
    foreignKeys = [ForeignKey(
        entity = OrderEntity::class,
        parentColumns = ["id"],
        childColumns = ["order_id"],
        onDelete = ForeignKey.CASCADE,
    )],
)
internal data class OrderLineEntity(
    @ColumnInfo(name = "order_id") val orderId: String,
    val sku: String,
    val quantity: Int,
    @ColumnInfo(name = "amount_minor") val amountMinor: Long,
)
```

<!-- compile: android -->
```kotlin
// :data — com/acme/data/orders/OrderDao.kt
internal data class OrderWithLines(
    @Embedded val order: OrderEntity,
    @Relation(parentColumn = "id", entityColumn = "order_id")
    val lines: List<OrderLineEntity>,
)

@Dao
internal interface OrderDao {
    @Transaction
    @Query("SELECT * FROM orders WHERE customer_id = :customer ORDER BY placed_at DESC")
    fun observe(customer: String): Flow<List<OrderWithLines>>

    @Upsert suspend fun upsertOrders(orders: List<OrderEntity>)

    @Upsert suspend fun upsertLines(lines: List<OrderLineEntity>)

    @Transaction
    suspend fun replace(orders: List<OrderEntity>, lines: List<OrderLineEntity>) {
        upsertOrders(orders)
        upsertLines(lines)
    }
}
```

On a JVM server this family is a JPA `@Entity` (with the `all-open` and `no-arg` compiler plugins) or
an Exposed table object instead — a different set of annotations in the same module, mapped by the
same functions, hidden behind the same port. Engine choice and its Kotlin-specific traps are
`persistence-room-sqldelight` and `persistence-jvm-orm`; who wins when the cache and the network
disagree is `persistence-architecture`.

## Data — Mappers

Three families meet in one file, and nothing above `:data` imports it. Wire → domain first, where the
nullability of the payload collapses into the non-null guarantees the rules were written against:

<!-- compile: android -->
```kotlin
// :data — com/acme/data/orders/OrderMappers.kt
internal fun OrderDto.toDomain(): Order = Order(
    id = OrderId(requireNotNull(id) { "order without id" }),
    customer = CustomerId(requireNotNull(customerId) { "order $id without customer" }),
    placedAt = Instant.parse(requireNotNull(placedAt) { "order $id without placed_at" }),
    status = status.toOrderStatus(),
    currency = requireNotNull(currency) { "order $id without currency" },
    lines = lines.orEmpty().map(OrderLineDto::toDomain),
)

internal fun OrderLineDto.toDomain(): OrderLine = OrderLine(
    sku = requireNotNull(sku) { "line without sku" },
    quantity = quantity ?: 1,
    amount = Money(amountMinor ?: 0L),
)

/** An unknown status is data, not a crash: old clients keep working when the server adds one. */
private fun String?.toOrderStatus(): OrderStatus = when (this) {
    "placed" -> OrderStatus.Placed
    "paid" -> OrderStatus.Paid
    "shipped" -> OrderStatus.Shipped
    "cancelled" -> OrderStatus.Cancelled
    "archived" -> OrderStatus.Archived
    else -> OrderStatus.Unknown
}
```

Schema ↔ domain, both directions, because the cache is written as well as read:

<!-- compile: android -->
```kotlin
internal fun OrderWithLines.toDomain(): Order = Order(
    id = OrderId(order.id),
    customer = CustomerId(order.customerId),
    placedAt = Instant.fromEpochMilliseconds(order.placedAtMillis),
    status = order.status.toOrderStatus(),
    currency = order.currency,
    lines = lines.map { OrderLine(it.sku, it.quantity, Money(it.amountMinor)) },
)

internal fun Order.toEntity(): OrderEntity = OrderEntity(
    id = id.value,
    customerId = customer.value,
    placedAtMillis = placedAt.toEpochMilliseconds(),
    status = status.name.lowercase(),
    currency = currency,
)

internal fun Order.toLineEntities(): List<OrderLineEntity> =
    lines.map { OrderLineEntity(id.value, it.sku, it.quantity, it.amount.minor) }
```

Failure mapping is mapping too, and it belongs in the same place for the same reason — it is the
translation from someone else's vocabulary into the domain's. Two hops, because the transport's
vocabulary and the domain's are two vocabularies; the families themselves are `error-architecture`'s:

<!-- compile: android -->
```kotlin
import java.io.IOException
import retrofit2.HttpException

internal fun Throwable.toDataError(): DataError = when (this) {
    is DataError -> this
    is IOException -> DataError.Unreachable(this)
    is HttpException -> DataError.Http(code(), response()?.errorBody()?.problemType())
    else -> DataError.Malformed(this)
}

internal fun DataError.toOrderError(): OrderError = when (this) {
    is DataError.Unreachable -> OrderError.Offline
    is DataError.Http -> if (status == 404) OrderError.NotFound else OrderError.Unexpected(this)
    is DataError.Malformed, DataError.Empty -> OrderError.Unexpected(this)
}
```

Three notes:

- **`require` at the boundary, not `!!`.** The message names the field and the id, so the crash
  report is actionable; and because it is one function, turning "malformed payload" from a throw into
  a `Result.failure` later is one edit. Which one you want is `error-architecture`'s call.
- **`quantity ?: 1` is a business decision hiding in a mapper.** Defaults for missing fields are
  exactly the kind of thing that belongs in a use case or in the API contract. If you must default
  here, comment why; if the field is required, `requireNotNull` it and let the payload be wrong.
- **Mappers are functions, not injected objects.** A `Mapper<OrderDto, Order>` interface bound
  through DI adds a construction site and a stub nothing needs, because a pure function has no seam
  worth mocking.

## Data — Repository Implementation

The one place where "which source wins" is decided, and like everything else in `:data`, nothing
outside the module can construct it:

<!-- compile: android -->
```kotlin
// :data — com/acme/data/orders/OrderRepositoryImpl.kt
class OrderRepositoryImpl internal constructor(
    private val api: OrderApi,
    private val dao: OrderDao,
) : OrderRepository {

    override fun observeOrders(customer: CustomerId): Flow<List<Order>> =
        dao.observe(customer.value).map { rows -> rows.map(OrderWithLines::toDomain) }

    override suspend fun orders(customer: CustomerId): Result<List<Order>> {
        val refreshed = refresh(customer)
        val local = dao.observe(customer.value).first().map(OrderWithLines::toDomain)
        return when {
            refreshed.isSuccess -> Result.success(local)
            local.isNotEmpty() -> Result.success(local)   // stale beats empty
            else -> refreshed.map { local }               // no cache: the refresh failure is the answer
        }
    }

    override suspend fun refresh(customer: CustomerId): Result<Unit> = catching {
        val orders = api.orders(customer.value).map(OrderDto::toDomain)
        dao.replace(orders.map(Order::toEntity), orders.flatMap(Order::toLineEntities))
    }.mapFailure { it.toDataError().toOrderError() }

    override suspend fun order(id: OrderId): Result<Order> =
        catching { api.order(id.value).toDomain() }.mapFailure { it.toDataError().toOrderError() }

    override suspend fun cancel(id: OrderId): Result<Order> =
        catching { api.cancel(id.value).toDomain() }.mapFailure { it.toDataError().toOrderError() }
}
```

The binding ships from `:data` too, because `:data` is the only module that can call that
constructor; `:app` lists the module and never names the implementation:

<!-- compile: android -->
```kotlin
// :data — com/acme/data/orders/DataModule.kt
val dataModule = module {
    single<OrderRepository> { OrderRepositoryImpl(get(), get()) }
}
```

- **`catching`, not `runCatching` or a hand-written `catch`.** A screen the user left mid-load must
  not produce a `Result.failure`, or the ViewModel renders an error over a screen that is gone:
  `error-architecture` → "The runCatching Rule".
- **`internal constructor` on a public class.** Only `:data` can build it, because building it means
  naming `OrderApi` and `OrderDao`. The Koin module above, or its Hilt or Spring equivalent, is the
  one place that does (`di-koin`, `di-hilt`, `di-spring`).
- **No dispatcher, on purpose:** Room and Retrofit are on the "nothing to switch" rows of
  `concurrency-coroutines` → "Per-Layer Dispatchers".

On a server the repository itself makes the blocking JDBC call, so the switch sits here, around that
call and nothing else:

```kotlin
// :data — com/acme/data/orders/JdbcOrderRepository.kt (server)
class JdbcOrderRepository(
    private val database: Database,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : OrderRepository {

    override suspend fun orders(customer: CustomerId): Result<List<Order>> = catching {
        withContext(io) { transaction(database) { OrderTable.selectFor(customer.value) } }
    }.mapFailure { it.toDataError().toOrderError() }

    // observeOrders, refresh, order, cancel elided — same shape.
}
```

Which dispatcher a JDBC pool gets, and what virtual threads change about it:
`concurrency-coroutines` → "On the Server".

## Presentation — ViewModel

The presentation layer's entire view of everything below it is one constructor parameter —
`GetOrders`. The other two are its own formatters, declared in this module:

<!-- compile: android -->
```kotlin
// :feature:orders — com/acme/feature/orders/OrdersViewModel.kt
class OrdersViewModel(
    private val getOrders: GetOrders,
    private val dates: DateFormatter,
    private val money: MoneyFormatter,
    savedState: SavedStateHandle,
) : ViewModel() {

    private val customer = CustomerId(checkNotNull(savedState["customerId"]))
    private val _state = MutableStateFlow<OrdersUiState>(OrdersUiState.Loading)
    val state: StateFlow<OrdersUiState> = _state.asStateFlow()

    fun onEvent(event: OrdersUiEvent) = when (event) {
        OrdersUiEvent.Appeared, OrdersUiEvent.RetryClicked -> load()
    }

    private fun load() {
        viewModelScope.launch {
            _state.value = OrdersUiState.Loading
            _state.value = getOrders(customer).fold(
                onSuccess = { orders -> OrdersUiState.Content(orders.map { it.toRow(dates, money) }) },
                onFailure = { error -> OrdersUiState.Error(error.toUiMessage()) },
            )
        }
    }
}
```

`getOrders(customer)` is the `operator fun invoke` paying off: the call site reads as the verb, and
nothing about the repository, the DTO or the database is nameable from this module, because
`:feature:orders` does not depend on `:data`.

The third mapping boundary lives here, and it is presentation's own:

<!-- compile: android -->
```kotlin
// :feature:orders — domain → what the screen renders. Formatting is a UI concern.
import java.math.BigDecimal
import java.text.NumberFormat
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Currency
import java.util.Locale
import kotlin.time.toJavaInstant

class DateFormatter(private val zone: ZoneId) {
    private val format = DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
    fun medium(at: Instant): String = format.format(at.toJavaInstant().atZone(zone))
}

class MoneyFormatter(private val locale: Locale) {
    fun format(amount: Money, currency: String): String {
        val unit = Currency.getInstance(currency)
        val format = NumberFormat.getCurrencyInstance(locale).apply { this.currency = unit }
        return format.format(BigDecimal.valueOf(amount.minor, unit.defaultFractionDigits))
    }
}

internal fun Order.toRow(dates: DateFormatter, money: MoneyFormatter): OrderRow = OrderRow(
    id = id.value,
    title = "#" + id.value.takeLast(6),
    subtitle = dates.medium(placedAt),
    total = money.format(total, currency),
)

internal fun Throwable.toUiMessage(): UiMessage = when (this) {
    OrderError.Offline -> UiMessage.Resource(R.string.orders_offline)
    OrderError.NotFound -> UiMessage.Resource(R.string.orders_not_found)
    else -> UiMessage.Resource(R.string.orders_unexpected)
}
```

Everything else about this class — the `UiState` shape, one-shot effects, lifecycle-aware collection,
the navigation boundary, the event-style choice — is `arch-mvvm` and is deliberately not repeated
here. If the screen is a state machine rather than a load-and-render, the reducer that replaces
`onEvent` is `arch-mvi`; the use case above it does not change either way.

## Testing

One test per layer, each one allowed to touch exactly what its module is allowed to import.

**`:domain` — no framework, no runner, no context.** The fake is the port, hand-written, in
`:domain`'s test source set (move it into a `testFixtures` source set once `:data` and presentation
want it too — `pkg-gradle-modules`):

<!-- compile: android-test -->
```kotlin
// :domain/src/test — FakeOrderRepository.kt
class FakeOrderRepository(private val stored: List<Order> = emptyList()) : OrderRepository {
    var failure: OrderError? = null

    override suspend fun orders(customer: CustomerId): Result<List<Order>> =
        failure?.let { Result.failure(it) } ?: Result.success(stored)

    override fun observeOrders(customer: CustomerId): Flow<List<Order>> = flowOf(stored)

    override suspend fun refresh(customer: CustomerId): Result<Unit> =
        failure?.let { Result.failure(it) } ?: Result.success(Unit)

    override suspend fun order(id: OrderId): Result<Order> =
        stored.firstOrNull { it.id == id }
            ?.let { Result.success(it) }
            ?: Result.failure(OrderError.NotFound)

    override suspend fun cancel(id: OrderId): Result<Order> = order(id)
}
```

<!-- compile: android-test -->
```kotlin
// :domain/src/test — CancelOrderTest.kt
import kotlin.time.Clock
import kotlin.time.Duration.Companion.hours

class CancelOrderTest {
    private val clock = Clock.System   // replaced per test below

    @Test
    fun invoke_shippedOrder_rejectsWithoutRefund() = runTest {
        val orders = FakeOrderRepository(listOf(order.copy(status = OrderStatus.Shipped)))
        val payments = FakePaymentRepository()

        val result = CancelOrder(orders, payments, clock)(order.id)

        assertIs<OrderError.Rejected>(result.exceptionOrNull())
        assertEquals(emptyList(), payments.refunds)   // and nothing was refunded
    }

    @Test
    fun invoke_afterCancellationWindow_rejects() = runTest {
        val late = object : Clock { override fun now() = order.placedAt + 25.hours }
        val result = CancelOrder(FakeOrderRepository(listOf(order)), FakePaymentRepository(), late)(order.id)
        assertIs<OrderError.Rejected>(result.exceptionOrNull())
    }
}
```

The second assertion in the first test is the point of the layer: "no refund is issued for a shipped
order" is checkable in twelve lines with no database, no HTTP and no `Context`.

**`:data` — the module that owns the frameworks pays for them.** Mappers are pure-function tests over
a captured payload; the repository gets fakes for its sources and assertions on the *policy*:

```kotlin
// :data/src/test — OrderRepositoryImplTest.kt
@Test
fun orders_refreshFails_servesCache() = runTest {
    val api = FakeOrderApi().apply { failWith(IOException()) }
    val dao = FakeOrderDao(seeded = listOf(orderWithLines))

    val result = OrderRepositoryImpl(api, dao).orders(CustomerId("c-1"))

    assertEquals(1, result.getOrThrow().size)
}

@Test
fun toDomain_unknownStatus_mapsToUnknown() {
    val order = json.decodeFromString<OrderDto>(ORDER_WITH_FUTURE_STATUS).toDomain()
    assertEquals(OrderStatus.Unknown, order.status)
}
```

Against a real engine, one integration test per source is enough to prove the schema and the queries:

<!-- compile: ktor-test -->
```kotlin
// Server: the real database and the real migrations, in a container.
import org.testcontainers.junit.jupiter.Container
import org.testcontainers.junit.jupiter.Testcontainers
import org.testcontainers.postgresql.PostgreSQLContainer

@Testcontainers
class OrderTableTest {
    @Container val postgres = PostgreSQLContainer("postgres:16-alpine")
    // Flyway/Liquibase runs against it in @BeforeEach — persistence-migrations.
}
```

<!-- compile: android-test -->
```kotlin
// Android client: the real Room, no file on disk, on the JVM — Robolectric supplies the Context.
@RunWith(RobolectricTestRunner::class)
class OrderDaoTest {
    private val db = Room.inMemoryDatabaseBuilder(
        ApplicationProvider.getApplicationContext<Context>(), AppDatabase::class.java,
    ).allowMainThreadQueries().build()

    @After fun tearDown() = db.close()
}
```

**Presentation — fake use cases.** `GetOrders` is a final class, so the cheapest "fake" is the real
use case over the fake repository — which is usually what you want, since it exercises the rule the
screen depends on:

<!-- compile: android-test -->
```kotlin
// :feature:orders/src/test — OrdersViewModelTest.kt
import java.time.ZoneOffset
import java.util.Locale

@Test
fun onEvent_offlineFailure_rendersOfflineMessage() = runTest {
    val repo = FakeOrderRepository().apply { failure = OrderError.Offline }
    val viewModel = OrdersViewModel(
        getOrders = GetOrders(repo),
        dates = DateFormatter(ZoneOffset.UTC),
        money = MoneyFormatter(Locale.US),
        savedState = SavedStateHandle(mapOf("customerId" to "c-1")),
    )

    viewModel.state.test {
        assertEquals(OrdersUiState.Loading, awaitItem())
        viewModel.onEvent(OrdersUiEvent.Appeared)
        assertEquals(OrdersUiState.Error(UiMessage.Resource(R.string.orders_offline)), awaitItem())
        cancelAndIgnoreRemainingEvents()
    }
}
```

The formatters are real too: concrete classes with nothing to fake. A use case that reaches four
repositories still gets four fakes here rather than an interface of its own; it earns one only with a
second implementation: `arch-clean` → "Interfaces and Concrete Classes".
The `Main` replacement, Turbine and the rest of the harness:
`arch-mvvm` → "Testing ViewModel"

## Gradle Wiring

Four build files. The architecture is visible in what each one is missing.

```kotlin
// :domain/build.gradle.kts — no Android plugin, no framework, no sibling module.
plugins { kotlin("jvm") }

dependencies {
    implementation(libs.kotlinx.coroutines.core)

    testImplementation(kotlin("test"))
    testImplementation(libs.kotlinx.coroutines.test)
}
```

```kotlin
// :data/build.gradle.kts — every framework in the project lands here. kotlin("jvm") is the server
// and KMP-JVM shape; a :data that owns Room on Android applies the Android library plugin instead.
plugins {
    kotlin("jvm")
    alias(libs.plugins.ksp)
    alias(libs.plugins.kotlin.serialization)
}

dependencies {
    api(project(":domain"))   // api: this module hands back :domain types, so consumers need them
    implementation(libs.retrofit)
    implementation(libs.retrofit.kotlinx.serialization)
    implementation(libs.room.runtime)
    ksp(libs.room.compiler)

    testImplementation(kotlin("test"))
    testImplementation(libs.mockwebserver)
}
```

```kotlin
// :feature:orders/build.gradle.kts — the absent line is the one that matters: project(":data").
plugins {
    alias(libs.plugins.android.library)   // AGP 9 compiles Kotlin itself: no kotlin-android plugin
    alias(libs.plugins.compose.compiler)
}

dependencies {
    implementation(project(":domain"))
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    testImplementation(libs.turbine)
}
```

```kotlin
// :app/build.gradle.kts — the composition root, and the only module that may name :data.
dependencies {
    implementation(project(":domain"))
    implementation(project(":data"))
    implementation(project(":feature:orders"))
}
```

On KMP the rule is identical, one source set further in. `:domain` declares its targets and keeps
every file in `commonMain`; the absence of an `androidMain` or an `iosMain` here is the invariant —
a rule that needed one would not be a shared rule:

```kotlin
// :domain/build.gradle.kts — KMP
plugins { kotlin("multiplatform") }

kotlin {
    jvm()
    iosArm64(); iosSimulatorArm64()

    sourceSets {
        commonMain.dependencies {
            implementation(libs.kotlinx.coroutines.core)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation(libs.kotlinx.coroutines.test)
        }
    }
}
```

No Android target here. On AGP 9 that target is `android { }`, added by the Android KMP library
plugin (`com.android.kotlin.multiplatform.library`) — an Android plugin on the module, which is
precisely what Mistake 5 forbids `:domain` — so Android consumers take the `jvm()` variant. That
plugin is the one exception in the whole layout, and it belongs on `:data` when a platform driver
needs an Android API — never on `:domain`: `pkg-kmp-source-sets` → "Targets".

`:data` is multiplatform too, and it is the only module allowed an `iosMain` or an `androidMain` —
for a driver, never for a rule (`pkg-kmp-source-sets`). Two greps keep the whole thing honest in CI,
and they are cheaper than any review:

```bash
# The domain names no sibling module.
rg -n 'project\(":' domain/build.gradle.kts    # must print nothing

# Only the composition root names the data module.
rg -ln 'project\(":data"\)' --glob '**/build.gradle.kts'   # must print app/build.gradle.kts only
```
