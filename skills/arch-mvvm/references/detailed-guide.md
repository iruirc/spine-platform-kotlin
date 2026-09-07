# arch-mvvm — detailed guide

One screen — a list of orders that loads, fails, retries, refreshes and opens a detail — written
twice: once with a sealed `UiState`, once with a data-class one, plus the hybrid the third table row
recommends. Every section is self-contained; load the one you need, not the file.

Android imports are shown. `collectAsStateWithLifecycle()` and
`androidx.lifecycle.compose.LocalLifecycleOwner` are multiplatform since Lifecycle 2.8, so a Compose
Multiplatform screen in `commonMain` keeps this code as written — it is the Android screen. Only
Compose Desktop, which has no lifecycle to observe, swaps in `collectAsState()` and collects effects
in a plain `LaunchedEffect`. Read `Test Setup` for the test differences.

## Shared Pieces

Domain and formatting, identical under both UiState shapes.

```kotlin
// domain — plain Kotlin, no androidx, no Compose
@JvmInline
value class OrderId(val value: String)

data class Order(val id: OrderId, val title: String, val totalCents: Long)

interface OrderRepository {
    /** Throws on failure. Mapping the failure into UiState is the ViewModel's job. */
    suspend fun load(): List<Order>
}

fun interface MoneyFormatter {
    fun format(cents: Long): String
}
```

The ViewModel never resolves a localized string, so failures travel as a typed message and the
composable turns it into text (`error-architecture` covers the full hierarchy):

```kotlin
sealed interface UiMessage {
    data object Offline : UiMessage
    data object Unexpected : UiMessage
}

data class OrderRow(val id: OrderId, val title: String, val total: String)

fun Order.toRow(money: MoneyFormatter) = OrderRow(id, title, money.format(totalCents))
```

The fake both test sections use. A settable result and a call counter cover every case the mock
framework would have; nothing here pins the ViewModel to a call order.

```kotlin
class FakeOrderRepository : OrderRepository {
    private var result: Result<List<Order>> = Result.success(emptyList())
    var loadCount: Int = 0
        private set

    fun succeedWith(orders: List<Order>) { result = Result.success(orders) }
    fun failWith(error: Throwable) { result = Result.failure(error) }

    override suspend fun load(): List<Order> {
        loadCount++
        return result.getOrThrow()
    }
}

// String.format is JVM-only — on KMP the formatter is injected per platform.
val money = MoneyFormatter { cents -> "$%.2f".format(cents / 100.0) }
val beans = Order(OrderId("1"), "Coffee beans", totalCents = 1800)
val beansRow = OrderRow(OrderId("1"), "Coffee beans", "$18.00")
```

## Sealed UiState — ViewModel

Use this shape when the screen shows one thing at a time: a spinner, or a list, or an error pane.
There is no state in which a list and an error are both on screen, so the type forbids it.

```kotlin
sealed interface OrdersUiState {
    data object Loading : OrdersUiState
    data class Content(val orders: List<OrderRow>) : OrdersUiState
    data class Error(val message: UiMessage) : OrdersUiState
}

sealed interface OrdersUiEvent {
    data object Appeared : OrdersUiEvent
    data object RetryClicked : OrdersUiEvent
    data class OrderClicked(val id: OrderId) : OrdersUiEvent
}

sealed interface OrdersEffect {
    data class OpenOrder(val id: OrderId) : OrdersEffect
}
```

```kotlin
@HiltViewModel
class OrdersViewModel @Inject constructor(
    private val repository: OrderRepository,
    private val money: MoneyFormatter,
) : ViewModel() {

    private val _state = MutableStateFlow<OrdersUiState>(OrdersUiState.Loading)
    val state: StateFlow<OrdersUiState> = _state.asStateFlow()

    private val _effects = Channel<OrdersEffect>(Channel.BUFFERED)
    val effects: Flow<OrdersEffect> = _effects.receiveAsFlow()

    private var loadJob: Job? = null

    fun onEvent(event: OrdersUiEvent) {
        when (event) {
            OrdersUiEvent.Appeared -> if (loadJob == null) load()
            OrdersUiEvent.RetryClicked -> load()
            is OrdersUiEvent.OrderClicked -> _effects.trySend(OrdersEffect.OpenOrder(event.id))
        }
    }

    private fun load() {
        loadJob?.cancel()
        _state.value = OrdersUiState.Loading
        loadJob = viewModelScope.launch {
            try {
                _state.value = OrdersUiState.Content(repository.load().map { it.toRow(money) })
            } catch (e: CancellationException) {
                throw e                                  // never swallow cancellation
            } catch (e: IOException) {
                _state.value = OrdersUiState.Error(UiMessage.Offline)
            } catch (e: Exception) {
                _state.value = OrdersUiState.Error(UiMessage.Unexpected)
            }
        }
    }
}
```

Three things carry the design:

- `Appeared` guarded by `loadJob == null` replaces `init { load() }`: the first load is an event the
  Route sends, so a test can arrange the repository first and a retry re-runs the same path.
- `CancellationException` is rethrown before the broad catch. `runCatching` here would leave a
  cancelled screen sitting on stale content, because it catches cancellation as a failure.
- `trySend` on a `BUFFERED` channel never suspends, so `onEvent` stays a plain function.

## Sealed UiState — Screen

```kotlin
@Composable
fun OrdersRoute(
    onOpenOrder: (OrderId) -> Unit,
    modifier: Modifier = Modifier,
    viewModel: OrdersViewModel = hiltViewModel(),   // koinViewModel() on KMP/Desktop
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val lifecycle = LocalLifecycleOwner.current.lifecycle

    LaunchedEffect(viewModel, lifecycle) {
        viewModel.effects.flowWithLifecycle(lifecycle).collect { effect ->
            when (effect) {
                is OrdersEffect.OpenOrder -> onOpenOrder(effect.id)
            }
        }
    }
    LaunchedEffect(viewModel) { viewModel.onEvent(OrdersUiEvent.Appeared) }

    OrdersScreen(state = state, onEvent = viewModel::onEvent, modifier = modifier)
}
```

`flowWithLifecycle` is what keeps a back-stacked screen from navigating on top of the one the user is
looking at, and the `Channel` holds the rest until the screen resumes. One element can still be lost:
`receiveAsFlow()` may have taken it out of the channel at the instant collection is cancelled. Where
losing it is not acceptable, keep the effect in `UiState` behind a consume callback instead.

```kotlin
@Composable
fun OrdersScreen(
    state: OrdersUiState,
    onEvent: (OrdersUiEvent) -> Unit,
    modifier: Modifier = Modifier,
) {
    when (state) {
        OrdersUiState.Loading -> LoadingPane(modifier)
        is OrdersUiState.Error -> ErrorPane(
            message = state.message,
            onRetry = { onEvent(OrdersUiEvent.RetryClicked) },
            modifier = modifier,
        )
        is OrdersUiState.Content -> LazyColumn(modifier) {
            items(state.orders, key = { it.id.value }) { row ->
                OrderCard(row = row, onClick = { onEvent(OrdersUiEvent.OrderClicked(row.id)) })
            }
        }
    }
}

@Preview
@Composable
private fun OrdersScreenPreview() = AppTheme {
    OrdersScreen(state = OrdersUiState.Content(listOf(beansRow)), onEvent = {})
}
```

The preview is the check on the split: a stateless `OrdersScreen` needs no ViewModel, no DI graph and
no repository to render, which is also why a screenshot test can drive it directly.

## Sealed UiState — Test

```kotlin
class SealedOrdersViewModelTest {
    @get:Rule val mainDispatcherRule = MainDispatcherRule()

    private val repository = FakeOrderRepository()
    private fun viewModel() = OrdersViewModel(repository, money)

    @Test
    fun `appearing loads the orders`() = runTest {
        repository.succeedWith(listOf(beans))
        val viewModel = viewModel()

        viewModel.state.test {
            assertEquals(OrdersUiState.Loading, awaitItem())
            viewModel.onEvent(OrdersUiEvent.Appeared)
            assertEquals(OrdersUiState.Content(listOf(beansRow)), awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `retry after a network failure loads`() = runTest {
        repository.failWith(IOException())
        val viewModel = viewModel()

        viewModel.state.test {
            assertEquals(OrdersUiState.Loading, awaitItem())
            viewModel.onEvent(OrdersUiEvent.Appeared)
            assertEquals(OrdersUiState.Error(UiMessage.Offline), awaitItem())

            repository.succeedWith(listOf(beans))
            viewModel.onEvent(OrdersUiEvent.RetryClicked)
            assertEquals(OrdersUiState.Loading, awaitItem())
            assertEquals(OrdersUiState.Content(listOf(beansRow)), awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
        assertEquals(2, repository.loadCount)
    }

    @Test
    fun `appearing twice does not load twice`() = runTest {
        repository.succeedWith(listOf(beans))
        val viewModel = viewModel()

        viewModel.onEvent(OrdersUiEvent.Appeared)
        viewModel.onEvent(OrdersUiEvent.Appeared)
        advanceUntilIdle()

        assertEquals(1, repository.loadCount)
    }

    @Test
    fun `clicking an order emits the navigation effect`() = runTest {
        val viewModel = viewModel()

        viewModel.effects.test {
            viewModel.onEvent(OrdersUiEvent.OrderClicked(OrderId("7")))
            assertEquals(OrdersEffect.OpenOrder(OrderId("7")), awaitItem())
            cancelAndIgnoreRemainingEvents()
        }
    }
}
```

Notes that generalize:

- `StateFlow` conflates equal values, so the second `Loading` in the retry test is a real emission
  only because an `Error` sat between them. A test that expects a duplicate of the current value
  waits forever — that timeout is the assertion failing, not Turbine misbehaving.
- Effects get their own `test { }` block. A `Channel` nobody collects in a test is a navigation bug
  waiting to ship.
- `advanceUntilIdle()` is needed only where the assertion is about a side effect rather than an
  emission; `awaitItem()` already drives the `StandardTestDispatcher` forward.

## Data-class UiState — ViewModel

Use this shape when content stays on screen while something else happens to it: pull-to-refresh over
an existing list, an inline error banner above cached rows, a filter applied to loaded data.

```kotlin
data class OrdersUiState(
    val isLoading: Boolean = false,
    val isRefreshing: Boolean = false,
    val orders: List<OrderRow> = emptyList(),
    val error: UiMessage? = null,
) {
    val showEmptyPane: Boolean get() = !isLoading && error == null && orders.isEmpty()
}

// This shape earns one event the sealed section has no state for; the rest are unchanged.
sealed interface OrdersUiEvent {
    data object Appeared : OrdersUiEvent
    data object RetryClicked : OrdersUiEvent
    data object PullRefreshed : OrdersUiEvent
    data class OrderClicked(val id: OrderId) : OrdersUiEvent
}
```

The cost the table names is real: four fields have sixteen combinations and the screen renders about
five of them. Nothing but the ViewModel prevents the other eleven, so every transition sets the whole
set of fields it touches — including the ones it clears.

```kotlin
@HiltViewModel
class OrdersViewModel @Inject constructor(
    private val repository: OrderRepository,
    private val money: MoneyFormatter,
) : ViewModel() {

    private val _state = MutableStateFlow(OrdersUiState())
    val state: StateFlow<OrdersUiState> = _state.asStateFlow()

    private val _effects = Channel<OrdersEffect>(Channel.BUFFERED)
    val effects: Flow<OrdersEffect> = _effects.receiveAsFlow()

    private var loadJob: Job? = null

    fun onEvent(event: OrdersUiEvent) {
        when (event) {
            OrdersUiEvent.Appeared -> if (loadJob == null) load(refreshing = false)
            OrdersUiEvent.RetryClicked -> load(refreshing = false)
            OrdersUiEvent.PullRefreshed -> load(refreshing = true)
            is OrdersUiEvent.OrderClicked -> _effects.trySend(OrdersEffect.OpenOrder(event.id))
        }
    }

    private fun load(refreshing: Boolean) {
        loadJob?.cancel()
        // The first load blanks the screen; a refresh keeps the rows and clears only the error.
        _state.update {
            it.copy(isLoading = !refreshing, isRefreshing = refreshing, error = null)
        }
        loadJob = viewModelScope.launch {
            try {
                val rows = repository.load().map { it.toRow(money) }
                _state.update {
                    it.copy(isLoading = false, isRefreshing = false, orders = rows, error = null)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                val message = if (e is IOException) UiMessage.Offline else UiMessage.Unexpected
                _state.update { it.copy(isLoading = false, isRefreshing = false, error = message) }
            }
        }
    }
}
```

Every `update` above assigns both flags and the error. Leaving one field out is how `isLoading` and
`error` end up true at the same time, which is Mistake 10 in the skill.

## Data-class UiState — Screen

```kotlin
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrdersScreen(
    state: OrdersUiState,
    onEvent: (OrdersUiEvent) -> Unit,
    modifier: Modifier = Modifier,
) {
    PullToRefreshBox(
        isRefreshing = state.isRefreshing,
        onRefresh = { onEvent(OrdersUiEvent.PullRefreshed) },
        modifier = modifier,
    ) {
        Column {
            // The banner sits above content that is still on screen — the whole reason for this shape.
            state.error?.let { message ->
                ErrorBanner(message = message, onRetry = { onEvent(OrdersUiEvent.RetryClicked) })
            }
            when {
                state.isLoading -> LoadingPane()
                state.showEmptyPane -> EmptyPane()
                else -> LazyColumn {
                    items(state.orders, key = { it.id.value }) { row ->
                        OrderCard(row = row, onClick = { onEvent(OrdersUiEvent.OrderClicked(row.id)) })
                    }
                }
            }
        }
    }
}

@Preview
@Composable
private fun OrdersScreenRefreshFailedPreview() = AppTheme {
    OrdersScreen(
        state = OrdersUiState(orders = listOf(beansRow), error = UiMessage.Offline),
        onEvent = {},
    )
}
```

That preview is the state the sealed shape cannot express at all: rows plus an error. If no screen in
the project needs it, the sealed shape is the cheaper one.

## Data-class UiState — Test

```kotlin
class DataClassOrdersViewModelTest {
    @get:Rule val mainDispatcherRule = MainDispatcherRule()

    private val repository = FakeOrderRepository()
    private fun viewModel() = OrdersViewModel(repository, money)

    @Test
    fun `a refresh keeps the rows on screen`() = runTest {
        repository.succeedWith(listOf(beans))
        val viewModel = viewModel()

        viewModel.state.test {
            assertEquals(OrdersUiState(), awaitItem())
            viewModel.onEvent(OrdersUiEvent.Appeared)
            assertTrue(awaitItem().isLoading)
            assertEquals(listOf(beansRow), awaitItem().orders)

            viewModel.onEvent(OrdersUiEvent.PullRefreshed)
            with(awaitItem()) {
                assertTrue(isRefreshing)
                assertFalse(isLoading)
                assertEquals(listOf(beansRow), orders)   // the point of this shape
            }
            assertEquals(listOf(beansRow), awaitItem().orders)
            cancelAndIgnoreRemainingEvents()
        }
    }

    @Test
    fun `a failed refresh shows the banner over the old rows`() = runTest {
        repository.succeedWith(listOf(beans))
        val viewModel = viewModel()
        viewModel.onEvent(OrdersUiEvent.Appeared)
        advanceUntilIdle()

        repository.failWith(IOException())
        viewModel.onEvent(OrdersUiEvent.PullRefreshed)
        advanceUntilIdle()

        with(viewModel.state.value) {
            assertEquals(UiMessage.Offline, error)
            assertEquals(listOf(beansRow), orders)
            assertFalse(isLoading)
            assertFalse(isRefreshing)
        }
    }

    @Test
    fun `no state has both a spinner and an error`() = runTest {
        repository.failWith(IOException())
        val viewModel = viewModel()

        viewModel.state.test {
            skipItems(1)
            viewModel.onEvent(OrdersUiEvent.Appeared)
            repeat(2) {
                val state = awaitItem()
                assertFalse(state.isLoading && state.error != null)
            }
            cancelAndIgnoreRemainingEvents()
        }
    }
}
```

The third test is the tax this shape charges: the invalid combinations the sealed type made
unrepresentable have to be asserted away instead. Write it once per screen that uses the shape.

## Hybrid UiState

The row three shape: a data class for what coexists, a sealed field for what does not.

```kotlin
data class OrdersUiState(
    val content: Content = Content.Loading,
    val isRefreshing: Boolean = false,
    val banner: UiMessage? = null,
) {
    sealed interface Content {
        data object Loading : Content
        data class Loaded(val orders: List<OrderRow>) : Content
        data class Failed(val message: UiMessage) : Content
    }
}
```

```kotlin
private fun load(refreshing: Boolean) {
    loadJob?.cancel()
    _state.update {
        // A refresh leaves `content` alone, so loaded rows stay rendered underneath.
        if (refreshing) it.copy(isRefreshing = true, banner = null)
        else it.copy(content = OrdersUiState.Content.Loading, banner = null)
    }
    loadJob = viewModelScope.launch {
        try {
            val rows = repository.load().map { it.toRow(money) }
            _state.update {
                it.copy(content = OrdersUiState.Content.Loaded(rows), isRefreshing = false)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val message = if (e is IOException) UiMessage.Offline else UiMessage.Unexpected
            _state.update { current ->
                // A failed refresh keeps the rows and shows a banner; a failed first load replaces them.
                if (current.content is OrdersUiState.Content.Loaded) {
                    current.copy(isRefreshing = false, banner = message)
                } else {
                    current.copy(content = OrdersUiState.Content.Failed(message), isRefreshing = false)
                }
            }
        }
    }
}
```

The composable keeps the exhaustive `when` on `state.content` from the sealed section and the banner
and refresh indicator from the data-class one. That is the whole trade: one more type, and the
"spinner plus error" combination stops being expressible while "rows plus banner" stays expressible.

## One-shot Effects

The channel plumbing used above, complete, plus the state-driven alternative.

Three additions to `Shared Pieces` that this section uses:

```kotlin
interface OrderRepository {
    suspend fun load(): List<Order>
    suspend fun archive(id: OrderId)
}

sealed interface UiMessage {
    data object Offline : UiMessage
    data object Unexpected : UiMessage
    data object Archived : UiMessage
}

// Resolved in the composable, the only layer that has a Context.
fun UiMessage.resolve(context: Context): String = context.getString(
    when (this) {
        UiMessage.Offline -> R.string.orders_offline
        UiMessage.Unexpected -> R.string.orders_unexpected
        UiMessage.Archived -> R.string.orders_archived
    }
)
```

```kotlin
sealed interface OrdersEffect {
    data class OpenOrder(val id: OrderId) : OrdersEffect
    data class ShowSnackbar(val message: UiMessage) : OrdersEffect
}

// ViewModel
private val _effects = Channel<OrdersEffect>(Channel.BUFFERED)
val effects: Flow<OrdersEffect> = _effects.receiveAsFlow()

fun onArchiveClicked(id: OrderId) {
    viewModelScope.launch {
        try {
            repository.archive(id)
            _effects.send(OrdersEffect.ShowSnackbar(UiMessage.Archived))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _effects.send(OrdersEffect.ShowSnackbar(UiMessage.Unexpected))
        }
    }
}
```

```kotlin
// Route — the single collector, and the only place an effect becomes navigation
val snackbarHostState = remember { SnackbarHostState() }
val lifecycle = LocalLifecycleOwner.current.lifecycle
val context = LocalContext.current

LaunchedEffect(viewModel, lifecycle) {
    viewModel.effects.flowWithLifecycle(lifecycle).collect { effect ->
        when (effect) {
            is OrdersEffect.OpenOrder -> onOpenOrder(effect.id)
            is OrdersEffect.ShowSnackbar ->
                snackbarHostState.showSnackbar(effect.message.resolve(context))
        }
    }
}
```

`resolve(context)` runs in the composable, not the ViewModel — the rule that keeps `Context` out of
the ViewModel and the tests off a device. Note that `showSnackbar` suspends until the snackbar is
dismissed, so every later effect queues behind it; launch it in a child coroutine
(`launch { snackbarHostState.showSnackbar(…) }`) when a navigation must not wait for a message.

The state-driven alternative, for an effect that must survive process death (a payment result, a
completed wizard) — the flag lives in the state and the Screen reports back when it has acted:

```kotlin
data class CheckoutUiState(val paidOrderId: OrderId? = null)

// ViewModel
fun onNavigatedToReceipt() { _state.update { it.copy(paidOrderId = null) } }

// Route
LaunchedEffect(state.paidOrderId) {
    state.paidOrderId?.let { id ->
        onOpenReceipt(id)
        viewModel.onNavigatedToReceipt()
    }
}
```

It costs a field and a consume callback, and it is the only one of the three that comes back after
the process is killed, provided the field is written through `SavedStateHandle`. Use it there; use
the channel everywhere else.

## Test Setup

Dependencies: `org.jetbrains.kotlinx:kotlinx-coroutines-test` and `app.cash.turbine:turbine`, both
test-only.

```kotlin
// Android and any JVM source set with JUnit 4
class MainDispatcherRule(
    val dispatcher: TestDispatcher = StandardTestDispatcher(),
) : TestWatcher() {
    override fun starting(description: Description) = Dispatchers.setMain(dispatcher)
    override fun finished(description: Description) = Dispatchers.resetMain()
}
```

`viewModelScope` runs on `Dispatchers.Main.immediate` and takes no constructor parameter, so
`Dispatchers.setMain` is the only seam a ViewModel test has. Without it every test fails at
construction with "Module with the Main dispatcher had failed to initialize".

`commonTest` has no JUnit rules, so use the multiplatform annotations:

```kotlin
class OrdersViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @BeforeTest fun setUp() = Dispatchers.setMain(dispatcher)
    @AfterTest fun tearDown() = Dispatchers.resetMain()
}
```

Guidance that applies to every test above:

1. `StandardTestDispatcher` queues; `UnconfinedTestDispatcher` runs eagerly and hides the
   intermediate `Loading`. Reach for the unconfined one only when a test genuinely does not care
   about intermediate states.
2. Inject a dispatcher rather than calling `withContext(Dispatchers.IO)` inside the ViewModel where
   you can; when it is injected, pass `StandardTestDispatcher(testScheduler)` from inside `runTest`,
   or `mainDispatcherRule.dispatcher`, which is the same scheduler. A dispatcher built on any other
   scheduler is one `advanceUntilIdle()` never reaches. Layer-wide dispatcher placement is
   `concurrency-coroutines`.
3. Turbine's `awaitItem()` drives the scheduler, so most tests need no explicit `advanceUntilIdle()`;
   add it when the assertion is about a side effect (a call count, a repository write) instead.
4. `cancelAndIgnoreRemainingEvents()` at the end of a `test { }` block, or Turbine fails the test for
   unconsumed items — usually a real signal that the ViewModel emits more than the screen needs.
5. Fakes, not mocks. `FakeOrderRepository` above is 12 lines, is readable in a failure message, and
   survives a refactor of the call order that stubbing would have broken.
