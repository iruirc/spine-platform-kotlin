# compose-state — detailed guide

## Contents

- Shared Type
- Hoisting — Before
- Hoisting — After
- State Holder
- Saver for rememberSaveable
- Stability — The Unstable Class
- Stability — The Compiler Report
- Stability — The Fix
- Strong Skipping
- Side Effect Handlers
- derivedStateOf — Pays
- derivedStateOf — Does Not Pay
- Diagnosing — Compiler Metrics
- Diagnosing — recomposeHighlighter

## Shared Type

<!-- compile: android -->
```kotlin
import kotlinx.collections.immutable.ImmutableList

// :domain — a plain Kotlin module, no Compose compiler applied to it
data class Money(val cents: Long, val currency: String)

// :feature-orders
@Immutable
data class OrderRow(
    val id: String,
    val title: String,
    val isOpen: Boolean,
    val total: Money,
    val tags: ImmutableList<String>,
)
```

Every section reads this row. `Stability — The Unstable Class` shows it declared the naive way, and
`Stability — The Fix` says why each field is typed as it is; `ImmutableList` comes from
`kotlinx-collections-immutable`. Imports are Android's. On Compose Multiplatform the same code
compiles in `commonMain`; the two places that differ — `rememberSaveable` persistence and the Gradle
report block — say so where they come up.

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

<!-- compile: android -->
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

<!-- compile: android -->
```kotlin
import androidx.compose.runtime.saveable.rememberSaveable
import kotlinx.collections.immutable.toImmutableList

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrderScreen(
    orders: ImmutableList<OrderRow>,
    onOpen: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var query by rememberSaveable { mutableStateOf("") }
    var onlyOpen by rememberSaveable { mutableStateOf(false) }

    val visible = remember(orders, query, onlyOpen) {
        orders.filter {
            it.title.contains(query, ignoreCase = true) && (!onlyOpen || it.isOpen)
        }.toImmutableList()
    }

    Column(modifier) {
        TopAppBar(title = { Text("${visible.size} orders") })
        OrderSearchBar(query, onlyOpen, { query = it }, { onlyOpen = it })
        if (visible.isEmpty()) EmptyState() else OrderList(visible, onOpen)
    }
}
```

Both halves are now testable: `OrderSearchBar` with a value and a recording lambda, `OrderScreen`
with a list. Neither knows about a ViewModel; when the orders start arriving from one, only
`OrderScreen`'s caller changes. `TopAppBar` is still `@ExperimentalMaterial3Api`, so the screen that
uses it opts in.

Ship the stateful wrapper too, for callers with no opinion — the same pattern the Material components
use:

<!-- compile: android -->
```kotlin
import androidx.compose.runtime.saveable.rememberSaveable

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

<!-- compile: android -->
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

<!-- compile: android -->
```kotlin
@Composable
fun rememberOrderScreenState(
    listState: LazyListState = rememberLazyListState(),
    scope: CoroutineScope = rememberCoroutineScope(),
): OrderScreenState = remember(listState, scope) { OrderScreenState(listState, scope) }
```

Used from the screen, this collapses four `remember`s into one line. The icon is
`androidx.compose.material:material-icons-extended`, versioned by the Compose BOM — Material 3 does
not bring it:

<!-- compile: android -->
```kotlin
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward

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

// listSaver returns Saver<Original, Any>: the type arguments go on the call, not on the property
val DateRangeSaver = listSaver<DateRange, String>(
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
- **Outside Android there is no process-death story.** On Compose Desktop and on Multiplatform
  targets with no saved-state host, the value does not survive a process restart; under a
  `SaveableStateHolder` — installed by a navigation back stack or a tab host — it still survives
  leaving the composition, on every platform. The `Saver` is correct code either way; just do not
  build a desktop-only feature on the assumption that the value comes back after a restart.

## Stability — The Unstable Class

The order list scrolls badly and every row redraws when one row's badge changes. The row, declared
the naive way, looks innocent:

```kotlin
// :feature-orders — the Shared Type row before the fix
data class OrderRow(
    val id: String,
    val title: String,
    var isOpen: Boolean,
    val total: Money,
    val tags: List<String>,
)

@Composable
fun OrderList(orders: List<OrderRow>, onClick: (String) -> Unit) {
    LazyColumn {
        items(orders, key = { it.id }) { OrderCard(it, onClick) }
    }
}
```

Three separate defects, and each alone keeps the class from being stable:

1. `var isOpen` — a public mutable property that Compose is not told about, so the class cannot
   promise anything about its own contents.
2. `tags: List<String>` — the stdlib `List` interface carries no immutability promise; the instance
   behind it may be a `MutableList`.
3. `total: Money` — a class from a module the Compose compiler never saw, so it cannot be analysed
   and is treated as unstable.

## Stability — The Compiler Report

Turn on the reports (`Diagnosing — Compiler Metrics` has the Gradle block) and the compiler names all
three without guessing. From `<module>-classes.txt`, as the Kotlin 2.4 compiler writes it:

```
unstable class com.example.orders.OrderRow {
  stable val id: String
  stable val title: String
  stable var isOpen: Boolean
  unstable val total: Money
  runtime val tags: List<String>
  <runtime stability> = Unstable
}
```

Every defect has its line, though only one says `unstable`. `total` does: a class from another module
is unstable unless that module also applies the Compose compiler, or a stability configuration file
names it — and `:domain` does neither, so no report is emitted for `Money` at all. `tags` is
`runtime`, a stability left to the instance at run time, which a `List` never proves. `isOpen` reads
`stable var`: its type is stable, and the `var` is the defect the class line answers for. From
`<module>-composables.txt`:

```
restartable skippable scheme("[androidx.compose.ui.UiComposable]") fun com.example.orders.OrderList(
  orders: List<OrderRow>
  stable onClick: Function1<String, Unit>
)
```

Under strong skipping every restartable function reads `skippable`, so that word diagnoses nothing.
The parameter lines do: `orders` has no `stable` in front of it, so it is compared by instance
(`===`), and `OrderList` skips only while the caller hands it the very same list. A parameter marked
`unstable` — `OrderCard`'s `unstable row: OrderRow` in the same file — is compared the same way. Read
the two files together: the composables file says *which* parameter pays, the classes file says
*why*.

## Stability — The Fix

Each defect has one honest repair, and together they give the `OrderRow` of `Shared Type`:

1. `var isOpen` → `val`: it never changed after construction, so the mutability was the whole defect.
   If it must change in place, back it with `mutableStateOf` and mark the class `@Stable`, not
   `@Immutable`.
2. `List<String>` → `ImmutableList<String>` from `kotlinx.collections.immutable`.
3. `Money` → one of the two repairs below.

The list the screen passes takes the same type, so the parameter is stable too:

<!-- compile: android -->
```kotlin
@Composable
fun OrderList(orders: ImmutableList<OrderRow>, onClick: (String) -> Unit) {
    LazyColumn {
        items(orders, key = { it.id }) { OrderCard(it, onClick) }
    }
}
```

With the three fields repaired the compiler infers `stable class` on its own. `@Immutable` states the
promise — *no public property of this instance ever changes after construction* — and it is what a
class needs when the compiler cannot see its fields' types, in a module without the Compose compiler.
Use `@Stable` instead when the object does change and notifies Compose itself — a state holder, not a
value.

For the collection, add the dependency and build immutable instances at the edge that produces them:

```kotlin
// build.gradle.kts:  implementation(libs.kotlinx.collections.immutable)
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
    // singular `stabilityConfigurationFile` is the pre-2.0.20 spelling and is deprecated
    stabilityConfigurationFiles =
        listOf(rootProject.layout.projectDirectory.file("compose_compiler_config.conf"))
}
```

Re-run the report afterwards. The classes file should now read `stable class
com.example.orders.OrderRow`, and `OrderList`'s parameter `stable orders: ImmutableList<OrderRow>` —
compared by `equals` again. If it does not, the file still names the class the report does — the
report is the only evidence that counts.

## Strong Skipping

Strong skipping is on by default in the Compose compiler shipped with Kotlin 2.0.20 and later. It
changes two things, and it is worth knowing exactly which.

**1. A composable with unstable parameters becomes skippable**, comparing the unstable ones by
instance identity (`===`) instead of `equals`. The naive `OrderList` of `Stability — The Unstable
Class` skips *if and only if* the caller hands it the very same `List` instance.

```kotlin
// `rows: List<OrderRow>` is not stable, so strong skipping compares it with `===`
private val _state = MutableStateFlow(OrdersUiState(rows = emptyList()))

// defeats the skip: a fresh list instance on every emission — equal, but not identical
_state.update { it.copy(rows = orders.map(::toRow)) }

// earns it: the previous instance is kept when the mapping produced nothing new, so `===` holds
_state.update { current ->
    val rows = orders.map(::toRow)
    if (rows == current.rows) current else current.copy(rows = rows)
}
```

That is the whole reason stability still matters: strong skipping does **not** make an unstable type
stable, and most real screens rebuild their list on every emission. Holding the instance by hand, as
the second update does, works and has to be remembered at every write site. Make `rows` an
`ImmutableList` in an `@Immutable` state class instead and the parameter is stable again, so the
comparison goes back to structural equality and the skip happens with nobody maintaining it.

**2. Lambdas that capture unstable values are memoised** — the `onClick = { onClick(row.id) }` written
inside a `LazyColumn` item no longer allocates a new, unequal lambda per composition, so it stops
invalidating its child on its own. `@DontMemoize` opts a single lambda out when a capture must be
re-read every composition.

What it does not change:

- An unstable class is still reported `unstable`; the report is still the tool.
- `@Immutable` and immutable collections still decide whether a skip happens for a rebuilt value.
- Nothing about correctness: a `@Immutable` annotation that lies produces a stale screen with or
  without strong skipping.

There is no other mode left to reason about. Kotlin 2.4 deprecates
`ComposeFeatureFlag.StrongSkipping` at error level, so a build script that still disables it through
`featureFlags` no longer compiles, and Kotlin 2.5.0 removes the flag.

## Side Effect Handlers

Six handlers, one sample each, all on the same screen. The rule for each is in `SKILL.md`; here is
what it looks like and what the wrong version costs.

**`LaunchedEffect(key)`** — a coroutine tied to the composition, cancelled and restarted when a key
changes:

<!-- compile: android -->
```kotlin
@Composable
fun OrderDetailRoute(orderId: String, viewModel: OrderDetailViewModel = hiltViewModel()) {
    LaunchedEffect(orderId) { viewModel.load(orderId) }   // NOT LaunchedEffect(Unit)
    // …then collect the state and render the stateless OrderDetailScreen
}
```

With `Unit` as the key this loads the first order and never any other wherever the composable stays
in place while its argument changes — a detail pane beside the list, a pager page. Navigating to
another `orderId` in Navigation Compose hides the bug: that is a new back stack entry and a new
composition, even with `launchSingleTop`, so the effect runs again. Key on what the work depends on.
The route-level composable is the one that may hold a ViewModel — the stateless `OrderDetailScreen`
below it takes a state and a lambda (`arch-mvvm`).

**`rememberCoroutineScope()`** — for work started from a *callback*, not from composition:

<!-- compile: android -->
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

<!-- compile: android -->
```kotlin
import android.net.ConnectivityManager
import android.net.Network

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

<!-- compile: android -->
```kotlin
@Composable
fun Analytics(userId: String, tracker: AnalyticsTracker) {
    SideEffect { tracker.userId = userId }
}
```

An analytics *event* sent from here is sent on every recomposition. Events go in a keyed
`LaunchedEffect`.

**`produceState(initial, key)`** — turn a non-Compose source into a `State`:

<!-- compile: android -->
```kotlin
import android.graphics.Bitmap

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

<!-- compile: android -->
```kotlin
@Composable
fun EndlessOrders(listState: LazyListState, onLoadMore: () -> Unit) {
    LaunchedEffect(listState) {
        snapshotFlow { listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index }
            .collect { last -> if (last != null && last >= listState.layoutInfo.totalItemsCount - 5) onLoadMore() }
    }
}
```

It must be collected inside a coroutine, which is why it is always paired with a `LaunchedEffect`.
Reading `listState.layoutInfo` or `firstVisibleItemScrollOffset` directly in a composable body instead
makes that composable recompose on every scroll frame; `firstVisibleItemIndex` read there costs a
recomposition per row that scrolls past.

## derivedStateOf — Pays

The input changes with every row that scrolls past the top; the output changes twice a screen.
Without the wrapper, `OrderScreen` recomposes once per row scrolled past, for a boolean that almost
never moves.

<!-- compile: android -->
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

The compiler already knows which parameters it compares by instance. Ask it before annotating
anything.

```kotlin
// feature-orders/build.gradle.kts
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.compose)       // the Compose compiler Gradle plugin, versioned with Kotlin
}

composeCompiler {
    reportsDestination = layout.buildDirectory.dir("compose_reports")
    metricsDestination = layout.buildDirectory.dir("compose_metrics")
}
```

Before Kotlin 2.0 the same two destinations were passed as
`-P plugin:androidx.compose.compiler.plugins.kotlin:reportsDestination=…` in `freeCompilerArgs`; the
report format is identical, so everything below still reads.

Compile only the variant that ships, because that is the one whose numbers matter:

```
./gradlew :feature-orders:compileReleaseKotlin
```

Four files land in the destinations:

| File | What it answers |
|---|---|
| `compose_reports/<module>-composables.txt` | per function: `restartable`, `skippable`, `readonly`, and each parameter's stability |
| `compose_reports/<module>-classes.txt` | per class: `stable` / `unstable` / `runtime`, with each property's line |
| `compose_reports/<module>-composables.csv` | the same functions as rows, for sorting and diffing between builds |
| `compose_metrics/<variant>/<module>-module.json` | totals — composables, skippable, restartable, and the unstable counts |

With AGP 9 the three report files carry no variant in their name: for the build above they are
`feature-orders-composables.txt` and its two siblings, and the next debug compile overwrites them.
Only the metrics file sits in a per-variant directory.

The working loop, in order:

1. **Read `-module.json` first.** Under strong skipping `skippableComposables` tracks
   `restartableComposables`, so the numbers worth comparing between two builds are
   `knownUnstableArguments` and `inferredUnstableClasses`.
2. **Grep the composables file for the screen you are profiling**, and find every parameter with no
   `stable` in front of it — `unstable`, or bare like `orders: List<OrderRow>`. Each is compared by
   instance.
3. **Take each such parameter's type to `-classes.txt`.** The property named there is the actual
   defect (`Stability — The Compiler Report`).
4. **Fix, rebuild, re-read.** Keep the previous `-composables.csv`; the diff is the evidence that the
   change did something.

Two traps. The reports describe *compilation*, not a run: a `skippable` function still recomposes if
its arguments genuinely change, and a report is not a substitute for measuring the screen. And the
files are overwritten per build, whichever variant it compiled — copy the baseline out before the
fix, or there is nothing to compare against.

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
release code. It is written with `Modifier.composed { }`, as the sample is; a modifier written today
should be a `Modifier.Node`, but this one is debug-only and copied verbatim, so diverging from the
sample buys nothing.

<!-- compile: android -->
```kotlin
// debug source set only — trimmed from the Compose samples' RecomposeHighlighter
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke

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

Red borders on rows the user never touched is the same finding as a parameter the report compares by
instance, arriving through the eyes instead of a file — which is why it is worth having both.

Reading the result honestly:

- **A debug build is not the timing you ship.** R8 is off, the debugger is attached, and the
  highlighter itself draws on every frame. Use these tools to find *where*, then confirm the *cost*
  on a release build.
- **Recomposition is not automatically a bug.** A row whose data really changed must recompose; the
  finding is the node that recomposes when its own inputs did not.
- **Change one thing per measurement.** Three annotations added at once produce a number that
  attributes to nothing.
