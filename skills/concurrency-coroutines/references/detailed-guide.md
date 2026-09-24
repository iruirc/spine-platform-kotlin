# concurrency-coroutines — detailed guide

## Contents

- Shared Type
- The Chain — Where withContext Sits
- Cancellation — ensureActive in a Loop
- Cancellation — Cleanup Under NonCancellable
- Cancellation — withTimeout and withTimeoutOrNull
- Fan-out — coroutineScope and async
- Fan-out — supervisorScope and Per-Child Failure
- App Scope — A Service That Outlives the Screen
- Android — WorkManager CoroutineWorker
- Shared State — Mutex
- Shared State — limitedParallelism for Blocking JDBC
- Server — Ktor Handlers
- Server — Spring WebFlux and Reactor Interop
- Server — Spring MVC and Virtual Threads
- Testing — runTest and Virtual Time
- Testing — Injected Dispatchers and setMain
- Testing — backgroundScope for Endless Collectors

## Shared Type

```kotlin
data class Order(val id: String, val total: Long)
```

Every `catching { }` below is the helper in
`error-architecture` → "The runCatching Rule".

Client samples are Android's and compile unchanged on Compose Multiplatform and Compose Desktop
except where noted; server samples name their framework.

## The Chain — Where withContext Sits

Four layers, one dispatcher switch, and it is in the layer that actually blocks.

```kotlin
// :presentation — on Dispatchers.Main.immediate, because viewModelScope is
class OrdersViewModel(private val loadOrders: LoadOrders) : ViewModel() {
    val state = MutableStateFlow(OrdersUiState())

    fun onOpen(userId: String) {
        viewModelScope.launch {                 // no dispatcher named here
            state.update { it.copy(isLoading = true) }
            val orders = loadOrders(userId)     // suspends; the hop happens further down
            state.update { it.copy(isLoading = false, orders = orders) }
        }
    }
}

// :domain — no dispatcher, no framework, no scope of its own
class LoadOrders(private val orders: OrderRepository) {
    suspend operator fun invoke(userId: String): List<Order> =
        orders.forUser(userId).filter { it.total > 0 }
}

// :data — composes sources and maps; still no switch
class DefaultOrderRepository(
    private val remote: OrderRemoteSource,
    private val local: OrderLocalSource,
) : OrderRepository {
    override suspend fun forUser(userId: String): List<Order> =
        remote.orders(userId).also { local.replaceAll(it) }
}

// :data — the network source suspends without holding a thread: nothing to switch
class RetrofitOrderSource(private val api: OrderApi) : OrderRemoteSource {
    override suspend fun orders(userId: String): List<Order> =
        api.orders(userId).map { Order(it.id, it.totalMinor) }
}

// :data — the one place the dispatcher is named, because SQLDelight blocks the caller
class SqlDelightOrderSource(
    private val queries: OrderQueries,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : OrderLocalSource {
    override suspend fun replaceAll(orders: List<Order>) = withContext(io) {
        queries.transaction {
            queries.deleteAll()
            orders.forEach { queries.insert(it.id, it.total) }
        }
    }
}
```

Cancellation reaches the socket: the `viewModelScope` job dies in `onCleared()`, the `await` chain
unwinds, Retrofit cancels the underlying `Call`. Every layer above `:data` is testable with a plain
fake and no dispatcher. Where Room replaces SQLDelight the `withContext` disappears — a `suspend` DAO
runs on Room's executor already — and returns only for what *surrounds* the call and blocks, such as
a file write.

## Cancellation — ensureActive in a Loop

A loop with no suspension point inside it never notices that its job was cancelled.

```kotlin
suspend fun parseAll(rows: List<RawRow>): List<Order> = withContext(Dispatchers.Default) {
    rows.map { row ->
        ensureActive()          // without it, the map runs on after the screen is gone
        expensiveParse(row)
    }
}
```

`ensureActive()` is a flag read and a throw, cheap enough to call per row. `yield()` does the same
check *and* offers the thread to other coroutines, which a long loop on a small `Default` pool needs
so it does not starve everything else. A polling loop takes `while (isActive)` for the same reason,
and a loop that already suspends needs neither.

## Cancellation — Cleanup Under NonCancellable

A cancelled coroutine still runs its `finally` blocks — but every suspending call inside them throws
immediately, because the job is already cancelled.

```kotlin
suspend fun upload(file: File) {
    try {
        api.upload(file)
    } finally {
        // a bare `storage.delete(file)` here is suspending, so on a cancelled job it
        // throws instantly and the temp file is never removed
        withContext(NonCancellable) { storage.delete(file) }
    }
}
```

Three constraints. The block must be short — an uncancellable section is one the caller cannot stop.
It must not do the work: `NonCancellable` around `api.upload(file)` turns an "upload keeps getting
cancelled" ticket into an upload nobody can cancel. And non-suspending cleanup needs none of this.

## Cancellation — withTimeout and withTimeoutOrNull

Both cancel the block when the deadline passes. They differ in what the caller gets.

```kotlin
// throws TimeoutCancellationException — the caller must handle it or it propagates
val orders = withTimeout(5.seconds) { loadOrders(userId) }

// returns null — the caller decides what "no answer in time" renders as
val orders = withTimeoutOrNull(5.seconds) { loadOrders(userId) } ?: emptyList()
```

`TimeoutCancellationException` is a `CancellationException`, with three consequences. A generic
`catch (e: Exception)` inside the block swallows the timeout and the block runs on past the deadline
— the same trap as `runCatching`. A timeout caught *outside* does not cancel the enclosing
coroutine: the exception belongs to the scope `withTimeout` created, not to its parent. And a
wrapper rethrowing every `CancellationException` rethrows a real expiry too, so the deadline never
becomes a visible failure — the reason `catching` has a timeout arm.

The client's connect/read/write timeouts answer a different question — they bound one attempt and
throw an `IOException` a retry layer can act on, while `withTimeout` bounds the whole operation
including its retries (`net-architecture`).

## Fan-out — coroutineScope and async

Three calls that together mean "open the dashboard". The parallelism is a domain fact, so it lives
in the use case.

```kotlin
class LoadDashboard(
    private val profiles: ProfileRepository,
    private val orders: OrderRepository,
    private val messages: MessageRepository,
) {
    suspend operator fun invoke(userId: String): Dashboard = coroutineScope {
        val profile = async { profiles.byId(userId) }
        val recent = async { orders.recent(userId) }
        val unread = async { messages.unreadCount(userId) }
        Dashboard(profile.await(), recent.await(), unread.await())
    }
}
```

`coroutineScope` is all-or-nothing, which is what a screen that cannot render without all three
wants: the first child to throw cancels its siblings and the exception comes out of the block, so
the caller writes one `try`. The scope does not return until every child has finished or been
cancelled, so nothing leaks past the function.

For a count known only at runtime, the same shape with `awaitAll()`:

```kotlin
suspend fun details(ids: List<String>): List<Order> =
    coroutineScope { ids.map { async { orders.byId(it) } }.awaitAll() }
```

Bound it when the list can be large: chunk the input, or route the calls through a source already
limited by a `Semaphore` or `Dispatchers.IO.limitedParallelism(n)`.

## Fan-out — supervisorScope and Per-Child Failure

The variant where the screen renders without one of the pieces: unread count is nice to have, and
its outage must not blank the dashboard.

```kotlin
suspend operator fun invoke(userId: String): Dashboard = supervisorScope {
    val profile = async { profiles.byId(userId) }
    val recent = async { orders.recent(userId) }
    val unread = async { messages.unreadCount(userId) }
    Dashboard(
        profile = profile.await(),                    // still fatal: no screen without it
        recent = recent.await(),
        unread = catching { unread.await() }.getOrNull(),
    )
}
```

Two rules make this correct rather than merely compiling. Under `supervisorScope` a failed `async`
holds its exception until someone calls `await()`, so an `async` nobody awaits is a lost failure:
await every child exactly once, inside `catching` if it may fail — `catching`, not `runCatching`,
because `await()` suspends. An await that is *not* wrapped behaves as before: `profile.await()`
throwing cancels the block, because supervision isolates children from each other, not from the
parent.

## App Scope — A Service That Outlives the Screen

One scope, created in the composition root, injected like anything else. On desktop and the server
this is the whole answer for background work.

```kotlin
// composition root (di-composition-root)
val appScope = CoroutineScope(
    SupervisorJob() +
        Dispatchers.Default +
        CoroutineExceptionHandler { _, e -> logger.error(e) { "unhandled in appScope" } },
)

class OutboxUploader(private val scope: CoroutineScope, private val api: OrderApi) {
    private val inFlight = ConcurrentHashMap<String, Job>()

    fun enqueue(order: Order): Job {
        val job = scope.launch { api.upload(order) }
        inFlight.put(order.id, job)?.cancel()          // re-enqueueing supersedes the running attempt
        job.invokeOnCompletion { inFlight.remove(order.id, job) }
        return job
    }
}
```

`SupervisorJob` is what makes the scope survive its first failure: on a plain `Job` one uncaught
throw cancels the scope, and every later `launch` returns a job that never runs — a bug that presents
as "uploads stopped working after some earlier error". The handler sits in the scope's context, the
only place it takes effect. Most callers enqueue and are done; the returned `Job` is there for the
rarer one that wants to stop what it started, without holding the scope. Shut the scope down with
`appScope.cancel()` (`release-ops-server`).

## Android — WorkManager CoroutineWorker

An app scope dies with the process, and Android kills backgrounded processes without asking. Work
that must survive that is `WorkManager`'s.

```kotlin
class SyncWorker(
    context: Context,
    params: WorkerParameters,
    private val sync: SyncOrders,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = try {
        sync()
        Result.success()
    } catch (e: CancellationException) {
        throw e                                  // the framework stopped us; not a failure
    } catch (e: IOException) {
        if (runAttemptCount < 3) Result.retry() else Result.failure()
    }
}
```

`doWork()` is `suspend` and runs on `Dispatchers.Default` unless the worker overrides
`coroutineContext`; the framework cancels it when its constraints stop holding, which is why the
`CancellationException` branch rethrows instead of returning `Result.failure()`. Injecting `sync`
needs a `WorkerFactory` binding (`di-hilt` covers `@HiltWorker`, `di-koin` the equivalent). The
request built around it carries the constraints and the backoff — `NetworkType.CONNECTED`,
`BackoffPolicy.EXPONENTIAL` — and goes in through `enqueueUniqueWork(name, KEEP, request)`, so a
second trigger does not start a second sync.

## Shared State — Mutex

Two coroutines, one value, no blocking.

```kotlin
class TokenCache(private val api: AuthApi) {
    private val mutex = Mutex()
    private var token: Token? = null

    suspend fun current(): Token {
        mutex.withLock { token }?.let { return it }
        val fresh = api.issue()                          // the network call is outside the lock
        return mutex.withLock { token ?: fresh.also { token = it } }
    }
}
```

`withLock` suspends rather than parking a thread, which is the reason not to reach for
`synchronized` — a blocked thread on `Dispatchers.Default` is one of very few. It is *not*
reentrant: a locked section calling another function that takes the same `Mutex` deadlocks, and the
stack trace names neither.

The shape above is what "keep the critical section to the mutation" costs: two short locked sections
with `api.issue()` between them, not one lock held across a network round trip that every other
caller queues behind. What it does not buy is single flight — two callers arriving together both call
`issue()` and one result is dropped. Collapsing that into one call, with a cached `Deferred` so N
concurrent 401s produce one refresh, is `net-architecture` → "Auth Refresh".

Two alternatives are often better. Confinement — state written from one coroutine only — needs no
lock. And `StateFlow.update { }`, an atomic compare-and-set loop, for state that is also observed:

```kotlin
state.update { it.copy(orders = it.orders + order) }   // atomic
state.value = state.value.copy(orders = ...)           // read-modify-write; loses updates
```

`AtomicInteger` / `AtomicReference` are for one independent value with nothing to stay consistent
with; the moment two atomics must agree, they are one state object behind a `Mutex`.

## Shared State — limitedParallelism for Blocking JDBC

`Dispatchers.IO` is elastic, up to 64 threads or the processor count, whichever is larger. A
connection pool of 10 is not, so dozens of coroutines calling JDBC means dozens of threads blocked
inside `DataSource.getConnection()`, invisible to every pool metric.

```kotlin
// one dispatcher per bounded resource, sized to it
private val jdbc = Dispatchers.IO.limitedParallelism(10)   // == HikariCP maximumPoolSize

class JdbcOrderRepository(private val ds: DataSource) : OrderRepository {
    override suspend fun byId(id: String): Order? = withContext(jdbc) {
        ds.connection.use { c -> c.prepareStatement(SQL).use { /* … */ } }
    }
}
```

`limitedParallelism(n)` is a **view** of `Dispatchers.IO`, not a new pool: it borrows the same threads
and caps how many this call site may hold at once. Create it once — a fresh view per call defeats the
point. Under Exposed this is `newSuspendedTransaction(Dispatchers.IO) { }` (`persistence-jvm-orm`).

## Server — Ktor Handlers

Every route body is already `suspend`, on the engine's dispatcher, inside the call's job.

```kotlin
routing {
    get("/orders/{id}") {
        val id = call.parameters.getOrFail("id")
        val order = try {
            withTimeout(3.seconds) { orders.byId(id) }    // null here means "no such order"
        } catch (e: TimeoutCancellationException) {
            return@get call.respond(HttpStatusCode.GatewayTimeout)
        }
        if (order == null) call.respond(HttpStatusCode.NotFound) else call.respond(order)
    }
}
```

`withTimeoutOrNull` would be shorter and wrong: it returns `null` for the deadline and the lookup
returns `null` for a missing row, so the handler cannot tell a slow database from an order that was
never there. When the block can itself return `null`, take `withTimeout` and catch.

The call's job is cancelled when the client disconnects, so the handler and everything it awaits stop
— provided nothing swallowed the `CancellationException`. A `StatusPages` handler mapping every
`Throwable` to a 500 is exactly that swallow; exclude cancellation explicitly.

## Server — Spring WebFlux and Reactor Interop

With `kotlinx-coroutines-reactor` on the classpath, controller methods may be `suspend` and may
return `Flow<T>`; Spring adapts both to reactive streams.

```kotlin
@RestController
class OrderController(private val orders: OrderService) {

    @GetMapping("/orders/{id}")
    suspend fun byId(@PathVariable id: String): Order = orders.byId(id)

    @GetMapping("/orders", produces = [MediaType.TEXT_EVENT_STREAM_VALUE])
    fun stream(): Flow<Order> = orders.stream()          // backpressure preserved
}
```

Three bridges cover the rest, and each is used once, at the edge:

```kotlin
val mono: Mono<Order> = mono { orders.byId(id) }         // suspending block → publisher
val order: Order? = webClient.get().retrieve()
    .bodyToMono<Order>().awaitSingleOrNull()             // publisher → suspending
val flow: Flow<Order> = repository.findAll().asFlow()    // Flux → Flow
```

Keep the middle suspending: a service taking and returning a `Mono` so it can call one reactive
repository has spread the other model through the layer. Never call `.block()` on a WebFlux
event-loop thread — `runBlocking` under another name, stalling every request that thread served.

## Server — Spring MVC and Virtual Threads

Spring MVC also accepts `suspend` handler methods, through the same `kotlinx-coroutines-reactor`
bridge and only when it is on the classpath: the handler is adapted and the request handled
asynchronously. It is not WebFlux — everything below the controller still blocks a thread.

```kotlin
// spring.threads.virtual.enabled=true makes the servlet container's threads virtual;
// this is the explicit dispatcher, for when the property is not enough
val loom = Executors.newVirtualThreadPerTaskExecutor().asCoroutineDispatcher()
```

What Loom changes and what it does not:

- **Changes:** a blocking call parks a virtual thread, not a platform one, so `Dispatchers.IO`'s
  thread limit stops being the constraint and `limitedParallelism` is no longer needed *for thread
  economy*.
- **Does not change:** anything with a real ceiling — a ten-connection pool is still ten
  connections, and unbounded callers only move the wait somewhere with no metric on it.
- **Watch out:** before JDK 24 a virtual thread blocking inside `synchronized` pins its carrier,
  which is exactly where older JDBC drivers block. `ReentrantLock` does not pin.

`runBlocking` has three homes on a server: `main()`, tests, and a blocking callback you do not
control — an OkHttp `Interceptor` or `Authenticator` (`net-http-clients`).

## Testing — runTest and Virtual Time

```kotlin
@Test fun byId_threeFailures_retriesTwiceThenFails() = runTest {
    val api = FlakyApi(failures = 3)
    val result = catching { RetryingOrders(api, delay = 30.seconds).byId("1") }

    assertTrue(result.isFailure)
    assertEquals(3, api.calls)
}
```

`runTest` runs the body on a `TestScope` whose scheduler drives virtual time: the two 30-second
backoff delays complete instantly. A test that actually waits is one where something escaped the
scheduler — a real dispatcher, a `Thread.sleep`, an executor. `advanceUntilIdle()` runs everything
queued, `advanceTimeBy(d)` what is due within `d`, `runCurrent()` only what is due now; under
`StandardTestDispatcher` nothing runs until one of them is called, which is what makes intermediate
states assertable.

## Testing — Injected Dispatchers and setMain

```kotlin
@ExtendWith(MainDispatcherExtension::class)
class OrdersViewModelTest {
    @Test fun onOpen_userWithOrders_showsThem() = runTest {
        val source = SqlDelightOrderSource(queries, io = StandardTestDispatcher(testScheduler))
        val vm = OrdersViewModel(LoadOrders(FakeRepository(source)))

        vm.onOpen("u1")
        advanceUntilIdle()

        assertEquals(2, vm.state.value.orders.size)
    }
}
```

Two seams, sharing one scheduler. `viewModelScope` runs on `Dispatchers.Main.immediate` and takes no
parameter, so replacing `Main` is the only way in; the test above is JUnit5 and uses the extension:
`test-frameworks` → "Main Dispatcher in Tests"

Every *other* dispatcher is a constructor parameter, and what goes in must be
`StandardTestDispatcher(testScheduler)` from `runTest`'s own scheduler (the `dispatcher` of the `Main`
replacement is the same one). A dispatcher on any other scheduler is one `advanceUntilIdle()` never
reaches: the test hangs, times out, or passes because the assertion ran before the work did.

## Testing — backgroundScope for Endless Collectors

`runTest` waits for the children of its own scope, so a collector that never completes hangs the
test forever.

```kotlin
@Test fun stream_orderInserted_emitsNewList() = runTest {
    val seen = mutableListOf<List<Order>>()
    backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
        repository.stream().toList(seen)          // never completes — and that is fine
    }

    repository.insert(Order("1", 100))
    advanceUntilIdle()

    assertEquals(1, seen.last().size)
}
```

`backgroundScope` is cancelled when the test body ends, so the collector is torn down instead of
awaited. The `UnconfinedTestDispatcher` is deliberate: the collector must be subscribed before the
first emission, and an unconfined dispatcher starts it eagerly at the `launch`. Cancellation deserves
a test of its own — cancel the job, then assert the effect: request aborted, cleanup ran, no state
written. That bug is invisible in a suite where everything runs to completion. Flow assertions with
Turbine are `reactive-flow`.
