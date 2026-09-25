# arch-mvi — detailed guide

## Contents

- Shared Pieces
- Hand-rolled — State and Intent
- Hand-rolled — Reducer
- Hand-rolled — Store
- Hand-rolled — Screen
- Hand-rolled — Reducer Test
- Orbit — Container
- Orbit — Screen
- Orbit — Test
- Test Setup

## Shared Pieces

Domain and mapping, identical under both implementations. Plain Kotlin: no `androidx`, no Compose,
compiles in a JVM test source set.

<!-- compile: android -->
```kotlin
@JvmInline
value class ResultId(val value: String)

data class SearchHit(val id: ResultId, val title: String, val year: Int)

enum class Filter { FreeOnly, RecentOnly }

interface SearchRepository {
    /** Throws on failure. Turning the failure into an intent is the executor's job. */
    suspend fun search(query: String, filters: Set<Filter>): List<SearchHit>
}
```

The store never resolves a localized string, so a failure travels as a typed message and the
composable turns it into text (`error-architecture` covers the real hierarchy):

<!-- compile: android -->
```kotlin
import java.io.IOException

sealed interface UiMessage {
    data object Offline : UiMessage
    data object Unexpected : UiMessage
}

data class ResultRow(val id: ResultId, val title: String, val subtitle: String)

fun SearchHit.toRow() = ResultRow(id, title, subtitle = year.toString())

fun Throwable.toUiMessage(): UiMessage = when (this) {
    is IOException -> UiMessage.Offline
    else -> UiMessage.Unexpected
}

/** Set toggle, the one helper the reducer calls — pure, so the reducer stays pure. */
fun <T> Set<T>.toggle(item: T): Set<T> = if (item in this) this - item else this + item
```

The fake both test sections use. A settable result plus the recorded queries covers every case a
mock would, and pins nothing to a call order:

<!-- compile: android -->
```kotlin
class FakeSearchRepository : SearchRepository {
    private var result: Result<List<SearchHit>> = Result.success(emptyList())
    val queries = mutableListOf<String>()

    fun succeedWith(hits: List<SearchHit>) { result = Result.success(hits) }
    fun failWith(error: Throwable) { result = Result.failure(error) }

    override suspend fun search(query: String, filters: Set<Filter>): List<SearchHit> {
        queries += query
        return result.getOrThrow()
    }
}

val hit = SearchHit(ResultId("1"), "Kotlin in Action", year = 2017)
val row = hit.toRow()
```

## Hand-rolled — State and Intent

One state type, and what the reducer takes split into two types by who may send it. `submittedQuery` is what
makes a late response answerable: it records which query the in-flight call belongs to, so the
reducer can drop an answer to a question the user has already changed.

<!-- compile: android -->
```kotlin
sealed interface Status {
    data object Idle : Status
    data object Loading : Status
    data class Failed(val message: UiMessage) : Status
}

data class SearchState(
    val query: String = "",           // what is in the text field right now
    val submittedQuery: String = "",  // what the in-flight (or shown) results answer
    val filters: Set<Filter> = emptySet(),
    val status: Status = Status.Idle,
    val results: List<ResultRow> = emptyList(),
) {
    val canSubmit: Boolean get() = query.isNotBlank() && status !is Status.Loading
}
```

`canSubmit` is a derived `get()`, not a stored field: a stored one is a fifth thing that can
disagree with the other four, and the reducer would have to remember to recompute it in every branch.

<!-- compile: android -->
```kotlin
sealed interface SearchAction

// The screen's real input surface — everything a composable may dispatch.
sealed interface SearchIntent : SearchAction {
    data class QueryChanged(val value: String) : SearchIntent
    data class FilterToggled(val filter: Filter) : SearchIntent
    data object SubmitClicked : SearchIntent
    data object RetryClicked : SearchIntent
    data class ResultClicked(val id: ResultId) : SearchIntent
}

// Results — sent by the executor. A sibling type, so no composable can forge a failure.
sealed interface SearchResult : SearchAction {
    data class ResultsLoaded(val rows: List<ResultRow>, val forQuery: String) : SearchResult
    data class LoadFailed(val error: UiMessage, val forQuery: String) : SearchResult
}

sealed interface SearchEffect {
    data class OpenResult(val id: ResultId) : SearchEffect
}
```

`internal` would not do this job: it is module visibility, and the Screen is in the store's module.
The public `dispatch(intent: SearchIntent)` is what keeps a Result out of a composable's reach.

## Hand-rolled — Reducer

A top-level function, named for its screen — which also keeps it apart from Orbit's own `reduce { }`
below. No receiver, no dependencies, no `suspend` — which is exactly why its test needs no
scaffolding at all.

<!-- compile: android -->
```kotlin
fun reduceSearch(state: SearchState, action: SearchAction): SearchState = when (action) {
    is SearchIntent.QueryChanged -> state.copy(query = action.value)

    is SearchIntent.FilterToggled -> state.copy(filters = state.filters.toggle(action.filter))

    SearchIntent.SubmitClicked ->
        if (!state.canSubmit) state
        else state.copy(submittedQuery = state.query, status = Status.Loading)

    SearchIntent.RetryClicked ->
        if (state.submittedQuery.isBlank() || state.status is Status.Loading) state
        else state.copy(status = Status.Loading)

    // Pure navigation: the effect is sent by the store, the state does not move.
    is SearchIntent.ResultClicked -> state

    is SearchResult.ResultsLoaded ->
        if (action.forQuery != state.submittedQuery) state
        else state.copy(status = Status.Idle, results = action.rows)

    is SearchResult.LoadFailed ->
        if (action.forQuery != state.submittedQuery) state
        else state.copy(status = Status.Failed(action.error))
}
```

Five of the seven branches can return `state` unchanged — every one but `QueryChanged` and
`FilterToggled`. Those returns are the pattern paying for itself: each is a race that used to be a
bug report, and each is one row in the table test.

Two decisions worth naming:

- **The guard lives in the reducer, not in the executor.** The executor cannot know whether the user
  changed the query while the call was in flight; the state can, and the check is one comparison.
- **`SubmitClicked` on a blank query is a no-op transition, not a rejected intent.** The UI never
  needs to know which intents are "allowed" — it dispatches what the user did, and the reducer
  decides what that means in the current state.

## Hand-rolled — Store

The store is a `ViewModel`, on Compose Desktop too (`arch-mvvm` → "ViewModel on Every Target"): it
owns the state, runs the reducer, and holds the executor that turns a `SubmitClicked` into a
`ResultsLoaded`.

```kotlin
@HiltViewModel
class SearchViewModel @Inject constructor(
    private val repository: SearchRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(SearchState())
    val state: StateFlow<SearchState> = _state.asStateFlow()

    private val _effects = Channel<SearchEffect>(Channel.BUFFERED)
    val effects: Flow<SearchEffect> = _effects.receiveAsFlow()

    private var searchJob: Job? = null

    fun dispatch(intent: SearchIntent) = process(intent)

    private fun process(action: SearchAction) {
        // One writer. `update` serializes two coroutines dispatching at the same moment,
        // and may re-run its lambda, so `before` is captured inside it.
        lateinit var before: SearchState
        val after = _state.updateAndGet { current -> before = current; reduceSearch(current, action) }
        execute(action, before, after)
    }

    private fun execute(action: SearchAction, before: SearchState, after: SearchState) {
        when (action) {
            SearchIntent.SubmitClicked, SearchIntent.RetryClicked ->
                if (after != before && after.status is Status.Loading) search(after)

            is SearchIntent.ResultClicked ->
                _effects.trySend(SearchEffect.OpenResult(action.id))

            else -> Unit   // QueryChanged, FilterToggled and the Results start no work
        }
    }

    private fun search(state: SearchState) {
        searchJob?.cancel()
        val forQuery = state.submittedQuery
        searchJob = viewModelScope.launch {
            val result = catching { repository.search(forQuery, state.filters) }.fold(
                onSuccess = { hits -> SearchResult.ResultsLoaded(hits.map(SearchHit::toRow), forQuery) },
                onFailure = { error -> SearchResult.LoadFailed(error.toUiMessage(), forQuery) },
            )
            process(result)
        }
    }
}
```

The executor gets the whole transition, not just its result. The new state is what it acts on — a
`SubmitClicked` executed against the old one would search the previous query — and the pair is what
tells it whether the reducer accepted the intent at all.

Four things this block is doing on purpose:

1. **The executor triggers on the transition, not on the state.** `after != before` is the reducer's
   own verdict; `after.status` alone would still read `Loading` from the search already in flight, so
   a submit the reducer refused would cancel it and restart it for the stale `submittedQuery`. The
   executor never re-implements the rule — it reads whether the rule fired.
2. **It reports back through `process`**, so the result goes through the same reducer as everything
   else and shows up in the same transition log — by the private path, not the public `dispatch`.
3. **`catching`, never `runCatching`.** A search cancelled by the next submit rethrows instead of
   arriving as a `LoadFailed`: `error-architecture` → "The runCatching Rule".
4. **`searchJob?.cancel()` plus the `forQuery` guard are both needed.** Cancellation is best-effort
   and races the response that is already decoding; the reducer's comparison is what actually decides.

## Hand-rolled — Screen

Two composables: a `Route` that owns the store and turns effects into navigation, and a stateless
`Screen(state, onIntent)` that previews and screenshot tests get.

```kotlin
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel

@Composable
fun SearchRoute(
    onOpenResult: (ResultId) -> Unit,
    viewModel: SearchViewModel = hiltViewModel(),   // koinViewModel() on KMP/Desktop
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val lifecycle = LocalLifecycleOwner.current.lifecycle

    LaunchedEffect(viewModel, lifecycle) {
        viewModel.effects.flowWithLifecycle(lifecycle).collect { effect ->
            when (effect) {
                is SearchEffect.OpenResult -> onOpenResult(effect.id)
            }
        }
    }
    SearchScreen(state = state, onIntent = viewModel::dispatch)
}
```

Keyed on `viewModel` and `lifecycle`, not on `Unit`: the collector restarts when the store instance
changes and at no other time. The same Route runs on Compose Desktop unchanged, where the window is
the lifecycle owner (`arch-mvvm` → "ViewModel on Every Target").

<!-- compile: android -->
```kotlin
@Composable
fun SearchScreen(state: SearchState, onIntent: (SearchIntent) -> Unit) {
    Column {
        TextField(
            value = state.query,
            onValueChange = { onIntent(SearchIntent.QueryChanged(it)) },
        )
        Row {
            Filter.entries.forEach { filter ->
                FilterChip(
                    selected = filter in state.filters,
                    onClick = { onIntent(SearchIntent.FilterToggled(filter)) },
                    label = { Text(filter.name) },
                )
            }
        }
        Button(
            onClick = { onIntent(SearchIntent.SubmitClicked) },
            enabled = state.canSubmit,
        ) { Text("Search") }

        when (val status = state.status) {
            Status.Loading -> CircularProgressIndicator()
            is Status.Failed -> ErrorPane(status.message, onRetry = { onIntent(SearchIntent.RetryClicked) })
            Status.Idle -> ResultList(state.results, onClick = { onIntent(SearchIntent.ResultClicked(it)) })
        }
    }
}
```

The whole UI surface is one lambda. Adding an intent adds a call site here and a branch in the
reducer; it never widens the `Screen` signature, which is the ergonomic MVI actually delivers.

Note what the composable does **not** do: no `try/catch`, no repository call, no formatting a year
into a subtitle. The mapping happened in `toRow` before the state existed, and every branch rendered
here was decided by the reducer.

## Hand-rolled — Reducer Test

The reducer is a pure function of two arguments, so the test is a table. No `runTest`, no
`Dispatchers.setMain`, no fake, no store — plain JUnit or `kotlin.test`, and it runs in the common
test source set on every KMP target.

<!-- compile: android-test -->
```kotlin
private data class Case(val state: SearchState, val action: SearchAction, val expected: SearchState)

class SearchReducerTest {

    private val loading = SearchState(query = "kotlin", submittedQuery = "kotlin", status = Status.Loading)

    @Test
    fun reduce_everyCase_returnsExpectedState() {
        val cases = listOf(
            Case(SearchState(query = "kotlin"), SearchIntent.SubmitClicked, loading),
            Case(SearchState(), SearchIntent.SubmitClicked, SearchState()),           // blank query: no-op
            Case(loading, SearchResult.ResultsLoaded(listOf(row), forQuery = "kotlin"),
                loading.copy(status = Status.Idle, results = listOf(row))),
            Case(loading, SearchResult.ResultsLoaded(listOf(row), forQuery = "ktor"), loading),
            Case(loading, SearchResult.LoadFailed(UiMessage.Offline, forQuery = "kotlin"),
                loading.copy(status = Status.Failed(UiMessage.Offline))),
            Case(loading, SearchIntent.QueryChanged("kt"), loading.copy(query = "kt")),
            Case(loading, SearchIntent.ResultClicked(ResultId("1")), loading),
        )
        cases.forEach { (state, action, expected) ->
            assertEquals(expected, reduceSearch(state, action), "$action on $state")
        }
    }
}
```

Row four is the whole reason this screen has a reducer: a response to `"ktor"` arriving while the
user waits on `"kotlin"` must change nothing. It is one line here and an unreproducible bug report
otherwise.

The message argument matters. A bare `assertEquals` inside a `forEach` reports "expected X, got Y"
with no hint which row failed, and a seven-row table then has to be bisected by hand.

The executor is a different test with a different seam — it asserts which **intents** the work
produced, never the state:

```kotlin
@ExtendWith(MainDispatcherExtension::class)
class SearchExecutorTest {
    @Test
    @DisplayName("a failed search comes back as LoadFailed")
    fun dispatch_searchFails_endsInFailedStatus() = runTest {
        val repository = FakeSearchRepository().apply { failWith(IOException()) }
        val viewModel = SearchViewModel(repository)

        viewModel.state.test {
            assertEquals(SearchState(), awaitItem())
            viewModel.dispatch(SearchIntent.QueryChanged("kotlin"))
            assertEquals("kotlin", awaitItem().query)
            viewModel.dispatch(SearchIntent.SubmitClicked)
            assertEquals(Status.Loading, awaitItem().status)
            assertEquals(Status.Failed(UiMessage.Offline), awaitItem().status)
            cancelAndIgnoreRemainingEvents()
        }
        assertEquals(listOf("kotlin"), repository.queries)
    }
}
```

Two tests, two seams: the transition table needs nothing, and the coroutine test needs everything but
covers only the four transitions that involve I/O. Splitting them is why the first one stays fast and
exhaustive.

## Orbit — Container

Orbit collapses the store's plumbing into a DSL: `intent { }` **is** the executor, `reduce { }` is
the only place the state moves, and `postSideEffect` is the only effect path. The state, intent and
effect types are unchanged from the hand-rolled half — and so is the pure reducer, which Orbit is
happy to call.

<!-- compile: android -->
```kotlin
class SearchViewModel(
    private val repository: SearchRepository,
) : ViewModel(), OrbitContainerHost<SearchState, SearchState, SearchEffect> {

    override val container = orbitContainer<SearchState, SearchEffect>(SearchState())

    private var searchJob: Job? = null

    fun dispatch(intent: SearchIntent) = process(intent)

    private fun process(action: SearchAction) = intent {
        lateinit var before: SearchState
        lateinit var after: SearchState
        reduce { before = state; reduceSearch(state, action).also { after = it } }   // the only state step
        when (action) {
            SearchIntent.SubmitClicked, SearchIntent.RetryClicked ->
                if (after != before && after.status is Status.Loading)
                    search(after.submittedQuery, after.filters)
            is SearchIntent.ResultClicked -> postSideEffect(SearchEffect.OpenResult(action.id))
            else -> Unit
        }
    }

    private fun search(forQuery: String, filters: Set<Filter>) {
        searchJob?.cancel()
        searchJob = viewModelScope.launch {
            val result = catching { repository.search(forQuery, filters) }.fold(
                onSuccess = { hits -> SearchResult.ResultsLoaded(hits.map(SearchHit::toRow), forQuery) },
                onFailure = { error -> SearchResult.LoadFailed(error.toUiMessage(), forQuery) },
            )
            process(result)
        }
    }
}
```

Every `intent { }` runs as a coroutine of its own, concurrently with the others, and only the
`reduce { }` lambda is applied as one atomic update. `state` read before and after `reduce { }` can
already include another intent's step, so the pair is captured inside the lambda — the same
transition the hand-rolled executor gets from `updateAndGet`, and with it the same rule: work starts
because the reducer moved the state, not because the state looks a certain way.

The suspending call is launched in `viewModelScope` and its answer re-enters as a Result, rather than
being awaited inside the `intent { }` block. Awaited in place it would block no other intent, but the
next submit could not cancel it, and its answer would reach the state by a path the transition table
never sees. Holding the `Job` and feeding the answer back keeps both.

Artifacts: `orbit-viewmodel` for the `orbitContainer(...)` call above — multiplatform in Orbit 12, so
the same class serves Android, Compose Desktop and `commonMain`; it binds the container to
`viewModelScope`, and to `SavedStateHandle` when given one with a `KSerializer` for the state.
`orbit-compose` is the UI side, and `orbit-core` alone serves a host that is not a `ViewModel` — that
one takes an explicit `CoroutineScope`.

## Orbit — Screen

`orbit-compose` supplies both halves of the binding, and both are lifecycle-aware already:
`collectAsState()` stops collecting below `STARTED`, and `collectSideEffect { }` buffers effects
while the screen is backgrounded rather than delivering them into a composition nobody is looking at.

<!-- compile: android -->
```kotlin
@Composable
fun SearchRoute(
    onOpenResult: (ResultId) -> Unit,
    viewModel: SearchViewModel = koinViewModel(),   // hiltViewModel() on Android-only
) {
    val state by viewModel.collectAsState()

    viewModel.collectSideEffect { effect ->
        when (effect) {
            is SearchEffect.OpenResult -> onOpenResult(effect.id)
        }
    }
    SearchScreen(state = state, onIntent = viewModel::dispatch)
}
```

Note what is missing compared with the hand-rolled Route: no `Channel`, no `LaunchedEffect`, no
`flowWithLifecycle`, no key to get wrong. That is the ceremony Orbit removes, and it is most of the
argument for taking the dependency.

`SearchScreen` itself is byte-identical to the hand-rolled one — it takes `(SearchState, (SearchIntent) -> Unit)`
and knows nothing about the container. The library is a Route-level decision, which is also why
migrating between the two touches one file per screen.

## Orbit — Test

`orbit-test` puts a container in test mode and asserts the sequence the DSL produced. It is the only
way to reach a `reduce { }` block: unlike the hand-rolled half, that block is not a function anyone
can call.

```kotlin
// `orbit-viewmodel` builds the container on viewModelScope, and search() launches into it.
@ExtendWith(MainDispatcherExtension::class)
class SearchViewModelTest {
    @Test
    @DisplayName("a submit searches and shows the rows")
    fun dispatch_submitClicked_searchesAndShowsRows() = runTest {
        val repository = FakeSearchRepository().apply { succeedWith(listOf(hit)) }

        SearchViewModel(repository).testWithInternalState(this) {
            containerHost.dispatch(SearchIntent.QueryChanged("kotlin"))
            expectInternalState { copy(query = "kotlin") }

            containerHost.dispatch(SearchIntent.SubmitClicked)
            expectInternalState { copy(submittedQuery = "kotlin", status = Status.Loading) }
            expectInternalState { copy(status = Status.Idle, results = listOf(row)) }
        }
    }

    @Test
    @DisplayName("a result click posts the open effect and does not move the state")
    fun dispatch_resultClicked_postsOpenEffectOnly() = runTest {
        SearchViewModel(FakeSearchRepository()).testWithInternalState(this) {
            containerHost.dispatch(SearchIntent.ResultClicked(ResultId("1")))
            expectSideEffect(SearchEffect.OpenResult(ResultId("1")))
        }
    }
}
```

Three things to know before writing more of these:

1. **`expectInternalState { }` is a `copy` on the previously expected state**, not on the live one,
   so the test spells out the whole state machine and a stray field change fails the next assertion,
   not a later one. The initial state is checked before the block runs.
2. **The container's state is a `StateFlow`**, so a transition that returns an equal state emits
   nothing — which is why the second test asserts only the effect. A test that waits for a state
   there hangs until the timeout.
3. **Keep the table test.** `orbit-test` covers the container: dispatch order, effects, the executor.
   The seven-row `SearchReducerTest` above still runs, still needs no coroutines, and is where a new
   transition gets its case. If the reducer had been written as a `reduce { }` lambda instead of a
   pure function, that test would not exist.

## Test Setup

Test-only dependencies, by what is being tested:

| Test | Needs |
|---|---|
| `SearchReducerTest` (the table) | `kotlin-test` or JUnit — nothing else |
| `SearchExecutorTest` (hand-rolled store) | `org.jetbrains.kotlinx:kotlinx-coroutines-test`, `app.cash.turbine:turbine` |
| `SearchViewModelTest` (Orbit) | `org.orbit-mvi:orbit-test`, `kotlinx-coroutines-test` — plus the `Main` replacement below |

Production side: `org.orbit-mvi:orbit-viewmodel` (`orbitContainer` bound to `viewModelScope`, on
every target), `org.orbit-mvi:orbit-compose` (`collectAsState`, `collectSideEffect`), or
`org.orbit-mvi:orbit-core` alone for a container host that is not a `ViewModel`.

The reducer test is the one that costs nothing to place: with no dispatcher and no framework it goes
straight into `commonTest` and runs on every KMP target (`pkg-kmp-source-sets`). Put it there first,
before deciding where the store's test lives.

Both store tests replace `Dispatchers.Main`, because `viewModelScope` runs on
`Dispatchers.Main.immediate` and takes no parameter; the samples above use the JUnit5 extension:
`test-frameworks` → "Main Dispatcher in Tests"

Dispatcher choice, Turbine and injected dispatchers do not change here — an `UnconfinedTestDispatcher`
would run the search eagerly and hide the `Status.Loading` this screen exists for:
`arch-mvvm` → "Testing ViewModel"

One rule is specific to this pattern: **assert the whole state, and let the table grow.** Adding an
intent means adding a row; a reducer test that only checks one field per case will pass on the `copy`
that silently cleared `results`, which is the most common way a reducer regresses.
