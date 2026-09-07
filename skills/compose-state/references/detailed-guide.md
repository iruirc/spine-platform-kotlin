# compose-state — detailed guide

One screen — a searchable, filterable order list with a scroll-to-top button — carried through every
decision in `SKILL.md`: hoisted, given a state holder, made skippable, wired to each effect handler,
and finally profiled. Every section is self-contained; load the one you need, not the file.

The row type all sections share:

```kotlin
data class OrderRow(val id: String, val title: String, val isOpen: Boolean)
```

Imports are Android's. On Compose Multiplatform the same code compiles in `commonMain`; the two
places that differ — `rememberSaveable` persistence and the Gradle report block — say so where they
come up.

## Hoisting — Before

Everything this composable needs, owned inside it. It renders correctly and is still the wrong shape.

```kotlin
@Composable
fun OrderSearch(orders: List<OrderRow>, modifier: Modifier = Modifier) {
    var query by remember { mutableStateOf("") }
    var onlyOpen by remember { mutableStateOf(false) }

    val visible = orders.filter {
        it.title.contains(query, ignoreCase = true) && (!onlyOpen || it.isOpen)
    }

    Column(modifier) {
        TextField(value = query, onValueChange = { query = it })
        FilterChip(
            selected = onlyOpen,
            onClick = { onlyOpen = !onlyOpen },
            label = { Text("Open only") },
        )
        LazyColumn {
            items(visible, key = { it.id }) { OrderCard(it) }
        }
    }
}
```

What the caller cannot do, and each is a real ticket:

- Show `"${visible.size} results"` in the app bar — the count exists only inside this function.
- Clear the query from a toolbar action, or preset it from a deep link.
- Render a screen-level empty state, because "nothing matched" is not visible from outside.
- Restore the query after process death: `remember` is gone, and there is no seam to swap in
  `rememberSaveable` from the call site.
- Preview or test the filtered result without driving the text field through the UI.

The tell is mechanical: a `remember { mutableStateOf(...) }` whose value some *other* composable
needs to read or write.

## Hoisting — After

State moves up to the lowest composable that must read it — here the screen, because the app bar
shows the count. Events come back as lambdas.

```kotlin
@Composable
fun OrderSearchBar(
    query: String,
    onlyOpen: Boolean,
    onQueryChange: (String) -> Unit,
    onOnlyOpenChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier) {
        TextField(value = query, onValueChange = onQueryChange)
        FilterChip(
            selected = onlyOpen,
            onClick = { onOnlyOpenChange(!onlyOpen) },
            label = { Text("Open only") },
        )
    }
}
```

The owner. `rememberSaveable` because the query is something the user produced; the filtered list is
`remember`ed on its inputs because recomputing it on an unrelated recomposition is waste, not
because it is state.

```kotlin
@Composable
fun OrderScreen(orders: List<OrderRow>, modifier: Modifier = Modifier) {
    var query by rememberSaveable { mutableStateOf("") }
    var onlyOpen by rememberSaveable { mutableStateOf(false) }

    val visible = remember(orders, query, onlyOpen) {
        orders.filter {
            it.title.contains(query, ignoreCase = true) && (!onlyOpen || it.isOpen)
        }
    }

    Column(modifier) {
        TopAppBar(title = { Text("${visible.size} orders") })
        OrderSearchBar(query, onlyOpen, { query = it }, { onlyOpen = it })
        if (visible.isEmpty()) EmptyState() else OrderList(visible)
    }
}
```

Both halves are now testable: `OrderSearchBar` with a value and a recording lambda, `OrderScreen`
with a list. Neither knows about a ViewModel; when the orders start arriving from one, only
`OrderScreen`'s caller changes.

Ship the stateful wrapper too, for callers with no opinion — the same pattern the Material components
use:

```kotlin
@Composable
fun OrderSearchBar(initialQuery: String = "", modifier: Modifier = Modifier) {
    var query by rememberSaveable { mutableStateOf(initialQuery) }
    var onlyOpen by rememberSaveable { mutableStateOf(false) }
    OrderSearchBar(query, onlyOpen, { query = it }, { onlyOpen = it }, modifier)
}
```

## State Holder

When the screen grows a scroll-to-top button, a snackbar host and a "hide the filter row while
scrolling down" rule, the screen composable becomes a pile of unrelated `remember`s. That cluster is
UI logic, and UI logic is a plain class — not a ViewModel, which would outlive the layout it
describes.

```kotlin
@Stable
class OrderScreenState(
    val listState: LazyListState,
    private val scope: CoroutineScope,
) {
    val showScrollToTop: Boolean by derivedStateOf { listState.firstVisibleItemIndex > 0 }

    var filtersVisible by mutableStateOf(true)
        private set

    fun onScrollDirection(isScrollingDown: Boolean) { filtersVisible = !isScrollingDown }

    fun scrollToTop() { scope.launch { listState.animateScrollToItem(0) } }
}
```

Three things make it honest, and all three are load-bearing: `@Stable` plus every changing property
backed by `mutableStateOf`, the setter kept private so the class is the only writer, and the
`CoroutineScope` taken as a constructor parameter rather than created inside — the caller owns the
lifetime.

The factory, by the naming convention Compose itself uses. The keys are what forces a new instance:

```kotlin
@Composable
fun rememberOrderScreenState(
    listState: LazyListState = rememberLazyListState(),
    scope: CoroutineScope = rememberCoroutineScope(),
): OrderScreenState = remember(listState, scope) { OrderScreenState(listState, scope) }
```

Used from the screen, this collapses four `remember`s into one line:

```kotlin
@Composable
fun OrderScreen(state: OrderScreenState = rememberOrderScreenState()) {
    if (state.showScrollToTop) {
        FloatingActionButton(onClick = state::scrollToTop) { Icon(Icons.Filled.ArrowUpward, null) }
    }
    LazyColumn(state = state.listState) { /* … */ }
}
```

Passing the holder as a defaulted parameter keeps it injectable: a test or a preview supplies one
with a pre-scrolled `LazyListState` and asserts the button without touching the UI.

What must **not** move into this class: the orders themselves, the loading flag, the retry. Those are
business state, they must survive rotation, and a `remember`ed holder loses them.

## Saver for rememberSaveable

`rememberSaveable` writes through Android's saved-instance-state mechanism, so it stores only what a
`Bundle` accepts — primitives, `String`, `Parcelable`, `Serializable`, arrays of those. Anything else
needs a `Saver` telling Compose how to reduce the value to a savable one and rebuild it.

```kotlin
data class DateRange(val from: LocalDate, val to: LocalDate)

val DateRangeSaver: Saver<DateRange, List<String>> = listSaver(
    save = { listOf(it.from.toString(), it.to.toString()) },
    restore = { DateRange(LocalDate.parse(it[0]), LocalDate.parse(it[1])) },
)

@Composable
fun rememberDateRange(initial: DateRange): MutableState<DateRange> =
    rememberSaveable(stateSaver = DateRangeSaver) { mutableStateOf(initial) }
```

`mapSaver` is the same idea with named keys, and is easier to evolve when the type gains a field:

```kotlin
val DateRangeMapSaver = mapSaver(
    save = { mapOf("from" to it.from.toString(), "to" to it.to.toString()) },
    restore = { DateRange(LocalDate.parse(it["from"] as String), LocalDate.parse(it["to"] as String)) },
)
```

Rules the compiler will not enforce:

- **`restore` must tolerate garbage.** It runs against a bundle written by a previous version of the
  app; returning `null` from it means "no saved value" and is the correct answer for anything you
  cannot parse.
- **Keep it small.** Everything saved is written on every stop, synchronously, on the main thread,
  into a transaction shared with the rest of the process. A list of orders belongs in a ViewModel
  plus a reload.
- **On Compose Desktop and on Multiplatform targets with no saved-state host, this degrades to
  `remember`.** The `Saver` is still correct code and still runs on Android; do not build a
  desktop-only feature on the assumption that the value comes back after a restart.

## Stability — The Unstable Class

The order list scrolls badly and every row redraws when one row's badge changes. The state type looks
innocent:

```kotlin
// :domain — a plain Kotlin module, no Compose compiler applied to it
data class Money(val cents: Long, val currency: String)

// :feature-orders
data class OrderRow(
    val id: String,
    val title: String,
    val total: Money,
    val tags: List<String>,
    var seen: Boolean,
)

@Composable
fun OrderList(orders: List<OrderRow>, onClick: (String) -> Unit) {
    LazyColumn {
        items(orders, key = { it.id }) { OrderCard(it, onClick) }
    }
}
```

Three separate defects, and each alone is enough to stop skipping:

1. `var seen` — a public mutable property that Compose is not told about, so the class cannot promise
   anything about its own contents.
2. `tags: List<String>` — the stdlib `List` interface carries no immutability promise; the instance
   behind it may be a `MutableList`.
3. `total: Money` — a class from a module the Compose compiler never saw, so its stability is unknown
   at compile time.

## Stability — The Compiler Report

Turn on the reports (`Diagnosing — Compiler Metrics` has the Gradle block) and the compiler names all
three without guessing. From `<module>-classes.txt`:

```
unstable class OrderRow {
  stable val id: String
  stable val title: String
  runtime val total: Money
  unstable val tags: List<String>
  unstable var seen: Boolean
  <runtime stability> = Unstable
}

runtime class Money {
  stable val cents: Long
  stable val currency: String
  <runtime stability> = Uncertain(Money)
}
```

`unstable` is a verdict; `runtime` means "cannot be decided here, ask at runtime" — which is what a
type from a non-Compose module gets. From `<module>-composables.txt`:

```
restartable scheme("[androidx.compose.ui.UiComposable]") fun OrderList(
  unstable orders: List<OrderRow>
  stable onClick: Function1<String, Unit>
)
```

`restartable` with no `skippable` next to it is the whole diagnosis: this function will re-execute
every time its parent does. Read the two files together — the composables file says *which* function
pays, the classes file says *why*.

## Stability — The Fix

Each defect has one honest repair.

```kotlin
// 1. mutable property → observable state, and the class stops lying
//    (or, if it never changes, make it a `val` and the problem disappears)
@Immutable
data class OrderRow(
    val id: String,
    val title: String,
    val total: Money,
    val tags: ImmutableList<String>,   // 2. kotlinx.collections.immutable
    val seen: Boolean,
)
```

`@Immutable` is a promise: *no public property of this instance ever changes after construction*.
Making the fields `val` of stable types is what earns it; the annotation only tells the compiler what
it could not prove across a module boundary. Use `@Stable` instead when the object does change and
notifies Compose itself — a state holder, not a value.

For the collection, add the dependency and build immutable instances at the edge that produces them:

```kotlin
// build.gradle.kts:  implementation("org.jetbrains.kotlinx:kotlinx-collections-immutable:<version>")
val rows: ImmutableList<OrderRow> = orders.map(::toRow).toImmutableList()
```

For `Money`, the third defect, there are two repairs and they are not equivalent:

- **Apply the Compose compiler to the `:domain` module.** Correct, and it makes every current and
  future type in that module analysable. It also puts a UI toolkit's compiler plugin on a module that
  has no UI.
- **Name the type in a stability configuration file.** Preferred for domain and third-party types.
  One file, one class per line, wildcards allowed:

```
# compose_compiler_config.conf
com.example.domain.Money
com.example.domain.*
java.time.LocalDate
```

```kotlin
composeCompiler {
    // list-valued (`stabilityConfigurationFiles`) in newer versions of the plugin
    stabilityConfigurationFile = rootProject.layout.projectDirectory.file("compose_compiler_config.conf")
}
```

Re-run the report afterwards. `OrderList` should now read `restartable skippable`, and `OrderRow`
`stable class`. If it does not, the file still names the class the report does — the report is the
only evidence that counts.

## Strong Skipping

Strong skipping is on by default in the Compose compiler shipped with Kotlin 2.0.20 and later. It
changes two things, and it is worth knowing exactly which.

**1. A composable with unstable parameters becomes skippable**, comparing the unstable ones by
instance identity (`===`) instead of `equals`. The `OrderList` above skips *if and only if* the caller
hands it the very same `List` instance.

```kotlin
// ViewModel — same instance across emissions, so OrderList skips under strong skipping
private val _state = MutableStateFlow(OrdersUiState(rows = persistentListOf()))

// …and this defeats it: a new List every emission, equal but not identical
_state.update { it.copy(rows = orders.map(::toRow)) }   // new instance, `===` fails
```

That is the whole reason stability still matters: strong skipping does **not** make an unstable type
stable, and most real screens rebuild their list on every emission. With `ImmutableList` and a stable
state class the comparison falls back to structural equality and the skip actually happens.

**2. Lambdas that capture unstable values are memoised** — the `onClick = { onClick(row.id) }` written
inside a `LazyColumn` item no longer allocates a new, unequal lambda per composition, so it stops
invalidating its child on its own. `@DontMemoize` opts a single lambda out when a capture must be
re-read every composition.

What it does not change:

- An unstable class is still reported `unstable`; the report is still the tool.
- `@Immutable` and immutable collections still decide whether a skip happens for a rebuilt value.
- Nothing about correctness: a `@Immutable` annotation that lies produces a stale screen with or
  without strong skipping.

It can be turned off through the plugin's `featureFlags` (`ComposeFeatureFlag.StrongSkipping`), which
is worth knowing only to explain a codebase that already did it.

## Side Effect Handlers

Six handlers, one sample each, all on the same screen. The rule for each is in `SKILL.md`; here is
what it looks like and what the wrong version costs.

**`LaunchedEffect(key)`** — a coroutine tied to the composition, cancelled and restarted when a key
changes:

```kotlin
@Composable
fun OrderDetail(orderId: String, viewModel: OrderDetailViewModel) {
    LaunchedEffect(orderId) { viewModel.load(orderId) }   // NOT LaunchedEffect(Unit)
    // …
}
```

With `Unit` as the key this loads the first order and never any other, because the navigation library
reuses the composable when only the argument changes. Key on what the work depends on.

**`rememberCoroutineScope()`** — for work started from a *callback*, not from composition:

```kotlin
@Composable
fun OrderScreen(snackbarHostState: SnackbarHostState) {
    val scope = rememberCoroutineScope()
    Button(onClick = {
        scope.launch { snackbarHostState.showSnackbar("Order archived") }
    }) { Text("Archive") }
}
```

The scope is cancelled when the composable leaves the composition, which is exactly what a snackbar
launched from a button should do. Reaching for it in the composable body instead of `LaunchedEffect`
means the scope is created on the first composition and the work is started on all of them.

**`DisposableEffect(key)`** — anything with a register/unregister pair:

```kotlin
@Composable
fun ConnectivityBanner(connectivity: ConnectivityManager) {
    var online by remember { mutableStateOf(true) }
    DisposableEffect(connectivity) {
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { online = true }
            override fun onLost(network: Network) { online = false }
        }
        connectivity.registerDefaultNetworkCallback(callback)
        onDispose { connectivity.unregisterNetworkCallback(callback) }
    }
    if (!online) OfflineBanner()
}
```

The block must end in `onDispose { }` — the compiler enforces it, which is the point of the handler.

**`SideEffect { }`** — publish committed Compose state to an object that knows nothing about Compose.
It runs after every successful composition, so it holds an assignment and nothing else:

```kotlin
@Composable
fun Analytics(userId: String, tracker: AnalyticsTracker) {
    SideEffect { tracker.userId = userId }
}
```

An analytics *event* sent from here is sent on every recomposition. Events go in a keyed
`LaunchedEffect`.

**`produceState(initial, key)`** — turn a non-Compose source into a `State`:

```kotlin
@Composable
fun rememberThumbnail(url: String, loader: ImageLoader): State<Bitmap?> =
    produceState<Bitmap?>(initialValue = null, url, loader) {
        value = loader.load(url)            // suspends; re-runs when url changes
    }
```

For a callback API the same block registers and releases: `produceState` gives an `awaitDispose { }`
for exactly that. This belongs in a composable only for view-scoped resources like an image; a
screen's data comes from the ViewModel.

**`snapshotFlow { }`** — the other direction, Compose state out into a `Flow`, emitting only when the
value read inside actually changes:

```kotlin
@Composable
fun EndlessOrders(listState: LazyListState, onLoadMore: () -> Unit) {
    LaunchedEffect(listState) {
        snapshotFlow { listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index }
            .distinctUntilChanged()
            .collect { last -> if (last != null && last >= listState.layoutInfo.totalItemsCount - 5) onLoadMore() }
    }
}
```

It must be collected inside a coroutine, which is why it is always paired with a `LaunchedEffect`.
Reading `listState.firstVisibleItemIndex` directly in a composable body instead makes that composable
recompose on every scrolled pixel.

## derivedStateOf — Pays

The input changes on every frame of a fling; the output changes twice a screen. Without the wrapper,
`OrderScreen` recomposes at 60–120 Hz while the user scrolls, for a boolean that almost never moves.

```kotlin
@Composable
fun OrderScreen(orders: ImmutableList<OrderRow>) {
    val listState = rememberLazyListState()

    // reads firstVisibleItemIndex; only the *boolean* invalidates readers
    val showScrollToTop by remember {
        derivedStateOf { listState.firstVisibleItemIndex > 0 }
    }

    Scaffold(
        floatingActionButton = { if (showScrollToTop) ScrollToTopButton(listState) },
    ) { padding ->
        LazyColumn(state = listState, contentPadding = padding) {
            items(orders, key = { it.id }) { OrderCard(it) }
        }
    }
}
```

Two details that are easy to get wrong:

- **`remember { derivedStateOf { } }`, not a bare `derivedStateOf { }`.** Without the `remember` a new
  derived state is allocated on every composition and observes nothing usefully.
- **No keys on that `remember`.** The block reads Compose state, and Compose state is tracked; keys
  would only rebuild the derivation when they change, which is not what governs it.

The same shape covers `listState.firstVisibleItemScrollOffset > threshold`, "is the last item
visible", and "is any item selected" over a `SnapshotStateMap` — high-frequency input, low-frequency
answer.

## derivedStateOf — Does Not Pay

The reflex version. It looks identical and buys nothing:

```kotlin
@Composable
fun BadOrderSearch(orders: ImmutableList<OrderRow>) {
    var query by rememberSaveable { mutableStateOf("") }

    // WRONG: the result changes on every keystroke, exactly as often as the input
    val visible by remember(orders) {
        derivedStateOf { orders.filter { it.title.contains(query, ignoreCase = true) } }
    }
    // …
}
```

`query` changes, `visible` changes — every time. The wrapper adds a snapshot observer and an
allocation and skips no recomposition, and the filter itself still runs on the composition's thread.
The honest version is a keyed `remember`, which caches on the inputs instead of observing them:

```kotlin
val visible = remember(orders, query) {
    orders.filter { it.title.contains(query, ignoreCase = true) }
}
```

Two more that fail the same test:

- **`derivedStateOf { user.name.uppercase() }`** — one input, one output, changing together. A plain
  expression, or `remember(user.name)` if the transform is expensive.
- **A derivation over ViewModel data** — put it in the ViewModel's `map`, where it is testable
  without a composition (`arch-mvvm`).

And one that fails for a different reason: an input that is not Compose state.

```kotlin
var count = 0                                         // plain var, not observed
val label by remember { derivedStateOf { "$count" } }  // never updates
```

Only reads of snapshot state (`mutableStateOf`, `LazyListState`, `SnapshotStateList`, a collected
`State`) are tracked. A plain variable read inside the block is invisible to Compose, and the derived
value freezes at its first computation with no warning.

## Diagnosing — Compiler Metrics

The compiler already knows which composables cannot skip. Ask it before annotating anything.

```kotlin
// feature-orders/build.gradle.kts
plugins {
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.compose.compiler)     // the Kotlin 2.0+ Compose compiler Gradle plugin
}

composeCompiler {
    reportsDestination = layout.buildDirectory.dir("compose_reports")
    metricsDestination = layout.buildDirectory.dir("compose_metrics")
}
```

Before Kotlin 2.0 the same two destinations were passed as
`-P plugin:androidx.compose.compiler.plugins.kotlin:reportsDestination=…` in `freeCompilerArgs`; the
report format is identical, so everything below still reads.

Build the variant that ships, because that is the one whose numbers matter:

```
./gradlew :feature-orders:assembleRelease
```

Four files land in the destinations:

| File | What it answers |
|---|---|
| `<module>-composables.txt` | per function: `restartable`, `skippable`, `readonly`, and each parameter's stability |
| `<module>-classes.txt` | per class: `stable` / `unstable` / `runtime`, with the property responsible |
| `<module>-composables.csv` | the same functions as rows, for sorting and diffing between builds |
| `<module>-module.json` | totals — composables, of which skippable and restartable |

The working loop, in order:

1. **Read `-module.json` first.** `skippableComposables` against `restartableComposables` is the
   module's headline number and the only thing worth comparing between two builds.
2. **Grep the composables file for the screen you are profiling**, and find every function that is
   `restartable` with no `skippable`.
3. **Take each `unstable` parameter to `-classes.txt`.** The property named there is the actual
   defect (`Stability — The Compiler Report`).
4. **Fix, rebuild, re-read.** Keep the previous `-composables.csv`; the diff is the evidence that the
   change did something.

Two traps. The reports describe *compilation*, not a run: a `skippable` function still recomposes if
its arguments genuinely change, and a report is not a substitute for measuring the screen. And the
files are overwritten per build — copy the baseline out before the fix, or there is nothing to
compare against.

## Diagnosing — recomposeHighlighter

The report says which functions *can* skip. Two tools say which ones actually recompose while the app
runs.

**Layout Inspector.** With a debuggable build attached, its component tree adds two columns per
composable: recomposition count and skip count. Interact with the screen and watch which counter
climbs while nothing on that part of the screen changed — that node is the bug. Reset the counts
between attempts, or the numbers describe the whole session rather than the interaction.

**`Modifier.recomposeHighlighter()`.** A border drawn around whatever just recomposed — the fastest
way to see a whole subtree invalidating together. This is a snippet from the official Compose
samples, **not a library dependency**: copy it into a `debug` source set and never let it reach
release code.

```kotlin
// debug source set only — trimmed from the Compose samples' RecomposeHighlighter
fun Modifier.recomposeHighlighter(): Modifier = this.then(recomposeModifier)

private val recomposeModifier = Modifier.composed {
    val totalCompositions = remember { arrayOf(0L) }
    totalCompositions[0]++

    val compositionsAtLastTimeout = remember { mutableLongStateOf(0L) }
    LaunchedEffect(totalCompositions[0]) {
        delay(3_000)
        compositionsAtLastTimeout.longValue = totalCompositions[0]
    }

    Modifier.drawWithCache {
        onDrawWithContent {
            drawContent()
            val recent = totalCompositions[0] - compositionsAtLastTimeout.longValue
            val color = when (recent) {
                0L -> return@onDrawWithContent
                1L -> Color.Blue
                2L -> Color.Green
                else -> Color.Red
            }
            drawRect(color = color, style = Stroke(width = 2.dp.toPx()))
        }
    }
}
```

Applied where the suspicion is, not everywhere:

```kotlin
LazyColumn(state = listState) {
    items(orders, key = { it.id }) { OrderCard(it, Modifier.recomposeHighlighter()) }
}
```

Red borders on rows the user never touched is the same finding as a `restartable` row in the report,
arriving through the eyes instead of a file — which is why it is worth having both.

Reading the result honestly:

- **A debug build is not the timing you ship.** R8 is off, the debugger is attached, and the
  highlighter itself draws on every frame. Use these tools to find *where*, then confirm the *cost*
  on a release build.
- **Recomposition is not automatically a bug.** A row whose data really changed must recompose; the
  finding is the node that recomposes when its own inputs did not.
- **Change one thing per measurement.** Three annotations added at once produce a number that
  attributes to nothing.
