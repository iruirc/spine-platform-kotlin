---
name: arch-mvi
description: "Use when implementing MVI (Model-View-Intent) in a Kotlin UI project. Covers pure MVI (Intent → Reducer → State) and MVVM-with-single-State, side-effect channels, choosing between hand-rolled reducers, Orbit MVI, MVIKotlin, Circuit and Molecule, Compose integration, and reducer testing."
---

# MVI in Kotlin

One screen, one `State`, one input channel of `Intent`s, and one **pure** function
`reduce(state, intent): State` that is the only place the state changes. This skill decides which
flavour of that shape you are actually building, which of five libraries carries it, and how the
reducer is tested. Everything the two patterns share — ViewModel lifetime, lifecycle-aware
collection, the navigation boundary — is `arch-mvvm` and is not repeated here.

> **Related skills:**
> - `arch-mvvm` — the default this pattern is measured against, and the owner of the shared half
> - `compose-state` — hoisting, `remember` vs `rememberSaveable`, stability and recomposition below the store
> - `nav-compose` — the route graph the screen sits in, and where its navigation lambdas come from
> - `reactive-flow` — `StateFlow` vs `SharedFlow`, `stateIn` started policies, Turbine
> - `concurrency-coroutines` — which scope owns the executor's work, and how cancellation reaches it
> - `error-architecture` — what a failed load becomes before it re-enters the loop as an intent
> - `di-hilt` — `@HiltViewModel` and assisted injection for a store on Android
> - `di-koin` — `viewModelOf` and the KMP, Compose Desktop and Ktor track
> - `architecture-choice` — the compass that forked here, and the tiebreak that sends you back to MVVM

## When to Use

- The active project guidance file's `## Stack` names `MVI`, or `architecture-choice` just landed there
- One screen has many interleaved inputs — a query field, filters, paging, a retry, a result
  arriving late — and the order between them decides what is on screen
- User asks "MVVM or MVI", "how do I write a reducer", "Orbit or MVIKotlin", "where do side effects
  go in MVI", "why does my reducer need a coroutine"
- A ViewModel has grown six `_state.update { }` call sites and a bug report that only reproduces when
  two of them race

Not for a screen with one load and one retry — that is `arch-mvvm`, and the reducer is ceremony over
a two-state machine. Not for a whole app: MVI is chosen per screen, and a codebase where three
screens have reducers and thirty do not is normal.

## When To Load The Reference

`references/detailed-guide.md` carries one search screen — query, filters, submit, a late result,
retry and an open-detail effect — written twice, hand-rolled and on Orbit. Load one section, not the
file: `rg -n "^## " skills/arch-mvi/references/detailed-guide.md`.

| Need | Reference sections |
|---|---|
| The domain, rows and fake every example shares | `Shared Pieces` |
| The state and intent types, and the pure reducer itself | `Hand-rolled — State and Intent`, `Hand-rolled — Reducer` |
| Wiring the loop: dispatch, executor, effect channel | `Hand-rolled — Store` |
| The composable that renders it and consumes effects | `Hand-rolled — Screen` |
| A table-driven reducer test with no dispatcher | `Hand-rolled — Reducer Test` |
| The same screen with `intent { }` / `reduce { }` and `postSideEffect` | `Orbit — Container`, `Orbit — Screen` |
| Asserting an Orbit flow end to end | `Orbit — Test` |
| Gradle coordinates, KMP source sets, what each test needs | `Test Setup` |

## Two Flavours

Both are called "MVI" in review. They are not the same commitment, and the difference is the input
surface, not the state.

| | Pure MVI | MVVM + Single State |
|---|---|---|
| Input surface | one `sealed interface Intent`, one `dispatch(intent)` | named functions on the ViewModel: `onQueryChange`, `onSubmit` |
| Transition | `reduce(state, intent): State` — a pure function callable with no ViewModel | `_state.update { it.copy(…) }` inline in each handler |
| Async work | an executor turns one intent into further intents; only intents move the state | the handler launches, then updates the state at each step |
| Types per screen | State, Intent, internal Result intents, Effect, reducer, store | State, Effect, ViewModel |
| Replay and logging | every transition is one `(state, intent)` pair; a log of intents replays the screen | each handler must be instrumented on its own |
| Pick when | inputs interleave, order decides the outcome, transitions are worth a table test | one state object is enough and the whole win is forbidding invalid combinations |

1. **The single `State` is the win both flavours share.** If the pain was three `StateFlow`s and a
   screen that renders four of eight combinations, MVVM + Single State fixes it today, and the
   reducer is not what you needed (`arch-mvvm`, Modelling UiState).
2. **Pure MVI buys one thing the half-step cannot**: transitions become data, so they are testable
   without a ViewModel, loggable as a stream, and replayable. Pay the extra types for that, not for
   the vocabulary.
3. **Do not call the half-step MVI in code review.** A reviewer who reads "MVI" looks for a reducer,
   finds `update { }` in six handlers, and files the wrong bug.
4. **One flavour per screen, one convention per project.** Mixing is how a new action ends up
   dispatched *and* handled by a named function that also writes the state.

## Core Shape

Three data types and one function. Everything else on the screen is plumbing around them.

```kotlin
sealed interface Status {
    data object Idle : Status
    data object Loading : Status
    data class Failed(val message: UiMessage) : Status
}

data class SearchState(
    val query: String = "",           // what is in the text field
    val submittedQuery: String = "",  // what the in-flight results answer
    val filters: Set<Filter> = emptySet(),
    val status: Status = Status.Idle,
    val results: List<ResultRow> = emptyList(),
)

sealed interface SearchIntent {
    data class QueryChanged(val value: String) : SearchIntent
    data class FilterToggled(val filter: Filter) : SearchIntent
    data object SubmitClicked : SearchIntent
    data object RetryClicked : SearchIntent

    // Results — sent by the executor, never by the UI.
    internal data class ResultsLoaded(val rows: List<ResultRow>, val forQuery: String) : SearchIntent
    internal data class LoadFailed(val error: UiMessage, val forQuery: String) : SearchIntent
}
```

```kotlin
fun reduce(state: SearchState, intent: SearchIntent): SearchState = when (intent) {
    is SearchIntent.QueryChanged -> state.copy(query = intent.value)
    is SearchIntent.FilterToggled -> state.copy(filters = state.filters.toggle(intent.filter))
    SearchIntent.SubmitClicked -> state.copy(submittedQuery = state.query, status = Status.Loading)
    SearchIntent.RetryClicked -> state.copy(status = Status.Loading)
    // A result that answers a query nobody is waiting for changes nothing.
    is SearchIntent.ResultsLoaded ->
        if (intent.forQuery != state.submittedQuery) state
        else state.copy(status = Status.Idle, results = intent.rows)
    is SearchIntent.LoadFailed ->
        if (intent.forQuery != state.submittedQuery) state
        else state.copy(status = Status.Failed(intent.error))
}
```

1. **`reduce` is pure.** No `suspend`, no dispatcher, no repository, no clock, no `Random`, no
   logging, no `trySend`. A reducer that needs a coroutine is a reducer doing the executor's job, and
   it takes the whole test story down with it.
2. **Async work lives in an executor beside the reducer**, and it reports back **as further
   intents** — `ResultsLoaded`, `LoadFailed`. Name them Results, keep them in the same sealed
   hierarchy (or a sibling one), and mark them internal so no composable can dispatch a `LoadFailed`.
3. **One intent in, one state out.** The reducer returns a state and nothing else; it never emits an
   effect and never starts work. Deciding *whether* to start work is the executor's, and it reads the
   whole transition — the intent plus the states either side of it — so an intent the reducer refused
   starts nothing.
4. **The store is the only writer.** `dispatch` runs `reduce` and assigns; every other component
   reads. If two coroutines can dispatch at once, serialize — a `MutableStateFlow.update { }` around
   `reduce`, an actor, or Orbit's own per-container dispatch queue.
5. **`State` must be a `data class` with equality that means something.** `distinctUntilChanged` in
   `StateFlow` is what stops the screen recomposing on every keystroke that changed nothing, and a
   `List` field also costs Compose skipping (`compose-state`).
6. **The store lives where a ViewModel would.** On Android and in `commonMain`, that *is* a
   `ViewModel` with `viewModelScope`; on Compose Desktop, an object owned by the window scope.

## Library Choice

| Library | Pick when | Watch out |
|---|---|---|
| Hand-rolled reducer | one or two screens need it | discipline: keep `reduce` pure |
| Orbit MVI | Android/KMP, want `intent { reduce { } }` DSL with minimal ceremony | side effects via `postSideEffect` only |
| MVIKotlin | KMP, want Store/Executor/Reducer separation and time-travel | more types per screen |
| Circuit (Slack) | Compose-first, presenter-as-composable | couples presentation to Compose runtime |
| Molecule | want the presenter to be a composable producing a StateFlow | needs the Compose compiler on non-UI modules |

1. **Start hand-rolled.** Two screens' worth is roughly sixty lines and no dependency; you find out
   whether the pattern earns its keep before it is in the version catalog.
2. **Orbit is the default when a library is wanted** on Android or KMP: `orbit-viewmodel` on
   Android, `orbit-compose` for the UI side, `orbit-core` alone for a `commonMain` container with no
   `androidx.lifecycle`. Its `intent { }` block *is* the executor and `reduce { }` is the only state
   step, so the purity rule is enforced by the DSL rather than by review.
3. **MVIKotlin when the separation is the point** — `Store`, `Executor`, `Reducer` and `Bootstrapper`
   as named types, with time-travel over a whole graph of stores. Same screen, roughly twice the
   type count; on a two-screen app that is the tax with none of the return.
4. **Circuit and Molecule are presentation-runtime decisions, not MVI libraries.** Both make the
   presenter a `@Composable` — Circuit pairs a `Presenter` with a `Ui` and its own navigation;
   Molecule's `moleculeFlow` / `launchMolecule` turns one into a `StateFlow` any consumer can read.
   Adopt either for the runtime, then decide the reducer question inside it.
5. **Never two.** A project on Orbit that adds MVIKotlin for one screen has two container lifecycles,
   two effect channels and two test idioms, and no reviewer holds both.

## Side Effects

An effect is what cannot be re-rendered: navigate away, show a snackbar, open a share sheet, fire a
haptic. Everything still true after a configuration change belongs in `State`.

```kotlin
private val _effects = Channel<SearchEffect>(Channel.BUFFERED)
val effects: Flow<SearchEffect> = _effects.receiveAsFlow()
```

1. **`Channel(Channel.BUFFERED)` + `receiveAsFlow()` is the default** for a hand-rolled store: one
   screen, one collector, buffered across the recreation gap. `arch-mvvm` states the trade-offs
   against a state field and a `SharedFlow`, and they apply here unchanged.
2. **Never put a one-shot in `State`.** A `navigateTo` field is a state that is true twice —
   once when set, once after rotation — and the second one navigates under the user.
3. **The reducer never emits.** Effects are sent by the executor, or by the store *after* `reduce`
   returns, from the branch that already knows the intent. Reducer purity is the reason a transition
   can be replayed in a test loop.
4. **On Orbit, `postSideEffect` is the only path**, and the container's `sideEffectFlow` the only
   consumer. Do not add a private `Channel` beside it: one screen with two effect streams has two
   delivery guarantees and one arrival order nobody controls.
5. **One `sealed interface SearchEffect` per screen**, so the Route's `when` stays exhaustive and a
   new effect is a compile error at the only place that handles them.

## Compose Integration

```kotlin
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

1. **`collectAsStateWithLifecycle()` on Android and in `commonMain`; `collectAsState()` on Compose
   Desktop only.** Same rule, same reasons as `arch-mvvm` — it is one pattern's worth of binding, not
   two.
2. **Key the effect `LaunchedEffect` on the store, not on `Unit`.** `LaunchedEffect(viewModel, lifecycle)`
   restarts collection exactly when one of those changes and never on an unrelated recomposition;
   `LaunchedEffect(Unit)` in a reused composition can leave the old collector running.
3. **`flowWithLifecycle(lifecycle)` is not optional on Android** — without it a backgrounded screen
   keeps consuming effects and navigates under the one the user is looking at. Compose Desktop, which
   has no lifecycle to observe, drops it and the `lifecycle` key with it.
4. **On Orbit, use `orbit-compose`**: `viewModel.collectAsState()` for the state and
   `viewModel.collectSideEffect { }` for effects. Both are lifecycle-aware already, so writing the
   `flowWithLifecycle` dance around them is duplicated machinery, not extra safety.
5. **The stateless half takes `(state, onIntent)` and nothing else.** A composable typed against the
   store cannot be previewed, and the `onIntent: (SearchIntent) -> Unit` signature is the one thing
   MVI gives the UI layer for free — one lambda, whatever the screen grows.
6. **Do not dispatch an intent from composition.** Text-field input is `onValueChange`, a first load
   is a `LaunchedEffect(Unit) { dispatch(Appeared) }` at the Route, and neither is a call in the
   render path where recomposition decides how often it runs.

## Testing Reducers

The reducer is a pure function, so its test is a table and needs no dispatcher, no `runTest`, no
`Dispatchers.setMain` and no fake.

```kotlin
@Test
fun `transitions`() {
    val cases = listOf(
        // state, intent, expected
        Triple(
            SearchState(query = "kotlin"), SubmitClicked,
            SearchState(query = "kotlin", submittedQuery = "kotlin", status = Loading),
        ),
        Triple(
            SearchState(submittedQuery = "kotlin", status = Loading),
            ResultsLoaded(listOf(row), forQuery = "kotlin"),
            SearchState(submittedQuery = "kotlin", status = Idle, results = listOf(row)),
        ),
        // A result answering a query nobody waits for is dropped.
        Triple(
            SearchState(submittedQuery = "ktor", status = Loading),
            ResultsLoaded(listOf(row), forQuery = "kotlin"),
            SearchState(submittedQuery = "ktor", status = Loading),
        ),
    )
    cases.forEach { (state, intent, expected) ->
        assertEquals(expected, reduce(state, intent), "$intent on $state")
    }
}
```

1. **One table, one assertion, JUnit or `kotlin.test`.** A reducer test that imports
   `kotlinx-coroutines-test` is a signal the reducer is not pure.
2. **Assert the whole state, not one field.** `assertEquals(expected, actual)` catches the `copy`
   that also cleared the results; `assertEquals(Loading, actual.status)` does not.
3. **Every case names its intent in the failure message** — a table failure that says only
   "expected X, got Y" makes you count rows.
4. **Cover the transitions that are supposed to do nothing**, especially a late `ResultsLoaded`
   arriving after the query changed. That is the bug MVI was adopted to prevent, and it is one row.
5. **The executor is tested separately**, with `runTest` and a fake repository, asserting *which
   intents it produced* — not the state. Two tests, two seams, neither needing the other's setup.
6. **On Orbit, use `orbit-test`**: `viewModel.test(this)` puts the container in test mode, and
   inside the block `expectInitialState()`, `expectState { copy(…) }` and
   `expectSideEffect(effect)` assert the sequence the DSL produced — `containerHost` is the handle
   the block gives you back for dispatching. It is the only way to reach an Orbit `reduce { }`
   block, which is not a standalone function.

## When Appropriate

- One screen whose inputs interleave: search-as-you-type with filters and paging, a multi-step form
  with cross-field validation, a media player with buffering, seek and network state
- A bug class that reads "it only happens if you tap X while Y is loading" — an ordering bug, which
  is exactly what a `(state, intent)` table pins down
- A team that already has fluency in one MVI library; `architecture-choice` asks about familiarity
  for this track precisely because the answer flips the recommendation
- A state machine worth drawing: if you drew it before writing it, the reducer is the drawing

Skip it when the screen is load / show / retry (`arch-mvvm`), when the pain is a fat ViewModel
orchestrating repositories (`arch-clean`), or when "unidirectional" is the whole argument — MVVM with
a single `UiState` is already unidirectional.

## Common Mistakes

1. **A `suspend fun reduce`, or a repository call inside it.** Now the transition needs a dispatcher
   to observe, the table test is gone, and two intents arriving together interleave inside the one
   function that was supposed to be atomic. Move the call to the executor and let it dispatch a
   Result intent.
2. **Effects kept in `State`** — a `navigateTo: ResultId?` field. It fires again after every
   configuration change until something remembers to null it out, and the "something" is the
   composable, which now writes state. Use the effect channel.
3. **UI-dispatchable Result intents.** `LoadFailed` in the same public sealed interface as
   `SubmitClicked` means a composable can fake a failure, and a reviewer cannot tell the screen's
   real input surface from the executor's. Split them, or keep the internal half `internal`.
4. **One intent per widget property** — `QueryTextChanged`, `QueryFocusChanged`, `QueryCleared`,
   `QuerySubmitted` — until the sealed interface has forty members and the reducer's `when` scrolls.
   Intents name user-meaningful actions, not field mutations.
5. **State that is not comparable** — a lambda, a `Flow`, a domain object without `equals` inside the
   `data class`. `StateFlow` de-duplicates by equality, so every dispatch now re-renders the screen,
   and MVI's cheapest property is the first one lost.
6. **A reducer that ignores the current state** — every branch returns `state.copy(...)` from the
   intent alone. That is a setter with extra steps; if no transition reads `state`, the pattern is
   not paying for itself and `arch-mvvm` is the honest answer.
7. **Reintroducing a second writer** — a `_state.value = …` somewhere outside `dispatch`, usually in
   `init` or a Flow collector. The reducer is no longer the whole story, and the transition log no
   longer replays the screen. Feed that collector's emissions in as intents.
8. **`LaunchedEffect(Unit)` around effect collection on Android**, with no `flowWithLifecycle`. The
   backgrounded screen keeps consuming, and the navigation lands under whatever the user opened
   next (mistake 1 of `arch-mvvm`'s binding rules, in its effect form).
9. **A library adopted for the word.** Orbit or MVIKotlin added to keep one screen's `when`
   exhaustive buys a container lifecycle, a testing idiom and a migration for the next reader — the
   hand-rolled sixty lines were the whole pattern.
10. **MVI everywhere.** Thirty CRUD screens with reducers is thirty screens of ceremony to protect
    against an ordering bug that only two of them can have. It is a per-screen choice; the compass
    says so and so does the fallback in `architecture-choice`'s When in Doubt table.
