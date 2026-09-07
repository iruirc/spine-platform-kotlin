---
name: reactive-flow
description: "Use when choosing between Flow, StateFlow and SharedFlow, sharing a cold flow (stateIn/shareIn and their started policies), migrating RxJava or LiveData to Flow, bridging Reactor on the server, and testing flows with Turbine."
---

# Flow, StateFlow and SharedFlow

Three types answering three different questions, one sharing policy that decides what the upstream
does while nobody is looking, and the operators between them. Which *scope* collects a flow and
what cancels the collection is `concurrency-coroutines`; this skill starts one line further down,
at what is being collected and how it is shared.

> **Related skills:**
> - `concurrency-coroutines` — the scope that owns a collection, `repeatOnLifecycle`, cancellation discipline
> - `arch-mvvm` — the ViewModel's `stateIn(viewModelScope, WhileSubscribed(5_000), initial)`, and the one-shot-effects decision
> - `arch-mvi` — the single `State` a reducer folds into, and the effect stream beside it
> - `compose-state` — `collectAsStateWithLifecycle()` on the collector side, `snapshotFlow { }` on the way back
> - `persistence-architecture` — the database `Flow` this skill shares, and the one-per-query rule over it
> - `net-architecture` — a polled or streamed endpoint exposed as a `Flow`, and where it is shared
> - `error-architecture` — what a `catch { }` on a flow hands the layer above it

## When to Use

- A repository, a ViewModel or a server service is about to expose a reactive type and nobody has
  said which one
- User asks "`StateFlow` or `SharedFlow`", "why does my flow restart on rotation", "why does the
  query run twice", "what is `WhileSubscribed(5_000)`", "how do I move this off RxJava", "how do I
  test a flow"
- Review finds a `MutableStateFlow` exposed without `asStateFlow()`, a `collect` nested in another
  `collect`, a `stateIn(Eagerly)` over a database query, or a `flowOn` at the bottom of a chain
- An Rx or `LiveData` codebase is being migrated and both models are live at once
- A Kotlin service sits on top of WebFlux and the domain code is starting to import `reactor.core`

Not for which scope collects, what cancels it, or which dispatcher a layer runs on — that is
`concurrency-coroutines`. Not for the shape of `UiState` or where one-shot effects go —
`arch-mvvm`. Not for what a failure becomes before the user reads it — `error-architecture`.

## Cold vs Hot

| Type | Cold or hot | Current value | Use it for |
|---|---|---|---|
| `Flow<T>` | cold — the builder body runs once **per collector** | none; nothing is stored | a query, a request, a stream that should start when someone asks and stop when they leave |
| `StateFlow<T>` | hot — always holds exactly one value | `.value`, readable without collecting | screen state, a setting, a connection status: anything with an answer to "what is it right now" |
| `SharedFlow<T>` | hot — every collector sees every emission, `replay` decides what a late one sees | none | events: each delivered once, and two identical ones both matter |

1. **Cold is the default everywhere below the owner.** A repository returns `Flow`, a DAO returns
   `Flow`, an API client returns `Flow`. Who shares it, on what scope and under what policy is a
   decision for the thing that has a lifetime — usually the ViewModel (`persistence-architecture`).
2. **`StateFlow` is a `SharedFlow` with `replay = 1`, conflation and equality de-duplication.** Not
   a sibling — a specialisation. If the question "what is it right now" has an answer, that answer
   is a `StateFlow`.
3. **The de-duplication is exactly why events are not state.** `StateFlow` drops a value equal to
   the current one, so two identical "show snackbar" emissions become one, while two identical
   screen states were the same screen anyway.
4. **Choose by what the *collector* needs on arrival.** The latest value immediately → `StateFlow`.
   Everything that happens while it is present, and nothing from before → `SharedFlow(replay = 0)`.
   Its own run of the upstream → a cold `Flow`.
5. **The mutable one never leaves the class.** `private val _state = MutableStateFlow(...)` plus
   `val state = _state.asStateFlow()`; the same for `asSharedFlow()`. An exposed `MutableStateFlow`
   is a public setter with extra steps.
6. **A one-shot effect stream is not a third answer to this question.** `Channel` versus
   `SharedFlow(replay = 0, extraBufferCapacity = 1)` is decided by `arch-mvvm`'s effects table, on
   delivery guarantees rather than on hot-versus-cold, and that decision is not redone here.

## stateIn and shareIn

```kotlin
class OrdersViewModel(repository: OrderRepository) : ViewModel() {
    val state: StateFlow<OrdersUiState> = repository.observe(customerId)
        .map(::toUiState)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), OrdersUiState())
}
```

| `started` | Upstream starts | Upstream stops | What it costs |
|---|---|---|---|
| `Eagerly` | at the `stateIn` call, collector or not | when the scope is cancelled | a cursor, a socket or a poll kept open for a screen nobody is looking at |
| `Lazily` | on the first collector | when the scope is cancelled | the same as `Eagerly` from the first collection onward; the laziness only delays the start |
| `WhileSubscribed(5_000)` | on the first collector | 5 s after the last one leaves | one restart for a collector that stays away longer than the timeout |

**`WhileSubscribed(5_000)` is the default, and the five seconds is the whole argument.** A
configuration change destroys the collector and recreates it in milliseconds, so the new collector
arrives well inside the window and the upstream is never restarted — no second query, no reconnect,
no flash of the initial value. Backgrounding the app stops the collection at `STARTED`
(`collectAsStateWithLifecycle()` or `repeatOnLifecycle`, per `concurrency-coroutines`), the window
expires, and the upstream stops with it. `Eagerly` and `Lazily` both keep it running there.

1. **Share where the lifetime is, not where the flow is built.** `stateIn(viewModelScope, …)` in the
   ViewModel. A repository that calls `stateIn` on an application scope has chosen one lifetime for
   every consumer it will ever have, including the ones that only wanted one value.
2. **`Eagerly` only when the upstream must already be warm** — a connection that takes seconds to
   establish, a prefetch — and only on a scope that actually ends.
3. **`Lazily` when the first collection should also be the last start**: expensive once, cheap
   forever, and the scope is narrower than the process.
4. **`stateIn` needs an initial value.** The overload without one is a `suspend fun` that waits for
   the upstream's first emission, so calling it from `init` leaves the screen with nothing to render
   until then. Give the state a `Loading` case instead (`arch-mvvm`).
5. **`replayExpirationMillis = 0` when a stale value must not come back.** `WhileSubscribed` keeps
   its cached value forever by default; passing `0` drops it when the upstream stops, so the next
   collector sees the initial value rather than yesterday's balance.
6. **`shareIn` for a stream with no meaningful current value** — deltas, ticks, a socket feed:

```kotlin
val events: SharedFlow<ServerEvent> = client.events()
    .shareIn(scope, SharingStarted.WhileSubscribed(5_000), replay = 0)
```

`replay = 0` gives a late collector nothing; `replay = 1` is a `StateFlow` without the initial value
and without the equality de-duplication, which is occasionally what a stream of distinct-but-equal
events actually wants.

## Operators Worth Knowing

| Operator | Rule |
|---|---|
| `combine` | latest of each, re-emitted whenever any input changes — and nothing at all until **every** input has emitted once |
| `zip` | pairs by index and waits for both, so one slow source throttles the other; almost never what a screen wants |
| `flatMapLatest` | a new outer value cancels the inner flow the previous one started — search-as-you-type, id-driven queries |
| `flatMapConcat` / `flatMapMerge` | run inner flows in order / concurrently, without cancelling; `flatMapMerge` takes a concurrency limit |
| `mapLatest` / `transformLatest` | the same cancellation for a suspending block rather than a nested flow |
| `distinctUntilChanged` | drop a value equal to the previous one; free inside `StateFlow`, needed on a cold flow |
| `conflate` | keep only the newest value while the collector is busy, drop the rest — rendering |
| `buffer` | keep every value in a bounded queue and let the collector fall behind — work nobody may lose |
| `debounce` | emit only after the source has been quiet for the timeout; the input-field operator |
| `sample` | emit the latest value on a fixed interval — a firehose, throttled, rather than a settling one |
| `onStart` / `onCompletion` | emit before the upstream runs / observe how it ended, including cancellation |
| `retryWhen` | decide per attempt from `(cause, attempt)`; return `false` and the exception continues downstream |
| `catch` | handle an **upstream** exception — log it, or `emitAll` a fallback; cancellation passes through untouched |
| `flowOn` | run everything **above** it on the given context; everything below stays in the collector's |

1. **`catch` goes below everything it must guard.** It sees only what was thrown upstream of it, so
   a `catch` written above the `map` that throws never runs, and none of them ever see an exception
   from the collector's own body — that needs a `try` around the collection. What the caught failure
   becomes is `error-architecture`.
2. **`flowOn` is upstream-only, and it is the single answer to "which thread does this chain run
   on".** The terminal operator always runs in the collecting coroutine's context; to move the
   collector, move the collection.
3. **`flatMapLatest` is the fix for a nested `collect`.** "When the outer value changes, restart the
   inner stream" is a named operator, not a control-flow problem.
4. **`combine` for independent sources, `zip` for paired ones.** Two flows that update on their own
   schedules are `combine`; needing `zip` on a UI stream usually means the two values came from one
   source and should never have been split.
5. **`conflate` and `buffer` decide what is dropped, not how fast anything runs.** Neither adds
   parallelism; they only say what happens to values a busy collector has not reached yet.

## RxJava to Flow

| RxJava | Kotlin |
|---|---|
| `Observable<T>`, `Flowable<T>` | `Flow<T>` — backpressure is the collector suspending the producer, so there is no strategy to pick |
| `Single<T>` | `suspend fun (): T` |
| `Maybe<T>` | `suspend fun (): T?` |
| `Completable` | `suspend fun (): Unit` |
| `PublishSubject<T>` | `MutableSharedFlow<T>()` |
| `BehaviorSubject<T>` | `MutableStateFlow<T>(initial)` |
| `ReplaySubject<T>` | `MutableSharedFlow<T>(replay = n)` |
| `subscribeOn(Schedulers.io())` | `flowOn(Dispatchers.IO)` |
| `observeOn(mainThread())` | collect in a coroutine already on that dispatcher, or `withContext` around the collection |
| `Disposable`, `CompositeDisposable` | the collecting scope's `Job` — cancel the scope, never each stream |
| `Schedulers.io()` / `Schedulers.computation()` | `Dispatchers.IO` / `Dispatchers.Default` |
| `switchMap` / `flatMap` / `concatMap` | `flatMapLatest` / `flatMapMerge` / `flatMapConcat` |
| `onErrorResumeNext` | `catch { emitAll(fallback) }` |
| `retryWhen` | `retryWhen { cause, attempt -> … }` |
| `Observable.interval` | `flow { while (true) { emit(Unit); delay(period) } }` — there is no built-in interval operator |

1. **Migrate at a boundary, not file by file.** `kotlinx-coroutines-rx3` (`-rx2` for RxJava 2) is
   built for exactly this: `Observable.asFlow()`, `Flow.asObservable()`, `Single.await()`,
   `Completable.await()`, and `rxSingle { }` / `rxObservable { }` in the other direction. Convert one
   interface's return types, bridge on the side that has not moved yet, and leave it compiling.
2. **`Disposable` has no analogue on purpose.** The scope *is* the disposal: nothing to collect into
   a `CompositeDisposable`, nothing to leak by forgetting to. This is the single largest deletion the
   migration makes (`concurrency-coroutines` owns which scope).
3. **`subscribeOn` was per-stream; `flowOn` is per-segment.** One `flowOn` near the source is usually
   the whole translation, and a second one lower down is a different segment, not an override.
4. **Rx's Subject habit is what produces the wrong hot type.** A `BehaviorSubject` is state and
   becomes `MutableStateFlow`; a `PublishSubject` is events and becomes `MutableSharedFlow`. Porting
   both to `MutableSharedFlow` because "Subject means shared" is Mistake 1 below.
5. **Delete the bridge when the last Rx type on that path is gone.** A permanent `asFlow()` at a
   boundary means two scheduling models in one call chain, and a `flowOn` that silently does nothing
   because the work already happened on an Rx scheduler above it.

## LiveData to StateFlow

| LiveData | Flow |
|---|---|
| `LiveData<T>` exposed from a ViewModel | `StateFlow<T>` with an initial value |
| `MutableLiveData<T>()` with no value yet | `MutableStateFlow<T?>(null)`, or a `Loading` case in the state |
| `observe(viewLifecycleOwner) { }` | `repeatOnLifecycle(STARTED) { collect { } }`, or `collectAsStateWithLifecycle()` |
| `Transformations.map` | `map` |
| `Transformations.switchMap` | `flatMapLatest` |
| `MediatorLiveData` | `combine` |
| `distinctUntilChanged()` | nothing — `StateFlow` conflates by `equals` already |
| `setValue` / `postValue` | `value =` from any thread, or `update { }` when two coroutines write |
| `liveData { }` builder | `flow { }` + `stateIn`, or `asLiveData()` while both models are alive |

1. **`lifecycle-livedata-ktx` bridges both directions** — `LiveData.asFlow()` and `Flow.asLiveData()`
   — so a ViewModel can expose a `StateFlow` while a Fragment nobody has touched yet still calls
   `observe`. Convert the ViewModels first and the views at their own pace.
2. **The initial value is the one real difference.** `LiveData` was legally empty; `StateFlow` is
   not. That is a modelling gain, not a nuisance: the "no value yet" case gets a name
   (`UiState.Loading`) instead of being a null nobody rendered.
3. **The lifecycle awareness moves to the collector.** `LiveData` stopped delivering below `STARTED`
   by itself; a `StateFlow` does not, and a bare `lifecycleScope.launch { collect { } }` is the
   regression the migration introduces (`concurrency-coroutines`).
4. **A chain that ended in `distinctUntilChanged()` loses that call, not the behaviour** — provided
   the state is a `data class` with a real `equals`. A state holding a lambda or an array de-duplicates
   nothing, which is the same trap `arch-mvi` names for reducers.
5. **`StateFlow.value` is readable from any thread**, where `LiveData.getValue()` was main-thread
   only. Convenient in tests, and no longer a reason to keep a mirror field.

## Reactor Interop

```kotlin
// adapter edge: the core never sees a Mono or a Flux
suspend fun byId(id: OrderId): Order? = repository.findById(id).awaitSingleOrNull()
fun orders(customer: CustomerId): Flow<Order> = repository.findByCustomer(customer).asFlow()

// the framework wants a reactive type back
@GetMapping("/orders", produces = [MediaType.TEXT_EVENT_STREAM_VALUE])
fun stream(): Flux<Order> = service.orders().asFlux()

fun handle(request: Request): Mono<Response> = mono { service.handle(request) }
```

1. **Convert once, at the edge** — the same rule `concurrency-coroutines` states for suspending
   handlers. A domain type that imports `reactor.core` needs `StepVerifier` to test and drags the
   whole operator vocabulary into code that only wanted a list.
2. **`kotlinx-coroutines-reactor` is the artifact to depend on.** `asFlow()`, `awaitSingle()`,
   `awaitSingleOrNull()` and `awaitFirstOrNull()` live in `kotlinx-coroutines-reactive` underneath
   it; `asFlux()`, `mono { }`, `flux { }` and `ReactorContext` are the Reactor-specific half.
   Depending on the Reactor artifact gets both.
3. **Pick the `await` by cardinality, not by habit.** `awaitSingle()` throws
   `NoSuchElementException` on an empty `Mono`; `awaitSingleOrNull()` returns `null`, which is what
   a "find by id" wants; `awaitFirstOrNull()` takes the head of a multi-element stream.
4. **Context propagation is not automatic everywhere.** `mono { }` and `flux { }` read the
   subscriber's Reactor `Context` into the coroutine context as a `ReactorContext` element, and
   `asFlux()` carries a `ReactorContext` from the coroutine context back out. Anything riding in
   that context — reactive security, tracing, an MDC bridge — survives those three conversions and
   nothing else, so a `Flux` consumed by a plain `awaitSingle()` inside a coroutine started
   elsewhere loses it.
5. **Stay on Reactor where the pipeline genuinely is Reactor's** — `Retry.backoff`, `windowUntil`,
   `groupBy` over a live stream, an existing WebFlux chain nobody is rewriting today. Convert at the
   boundary the moment the code below it is domain logic: it is testable with `runTest` and Turbine,
   and it stops importing a framework.
6. **Backpressure survives the conversion.** A `Flow` collector suspends its producer, and `asFlux()`
   honours `request(n)` through that same suspension, so a converted stream needs no
   `onBackpressureBuffer` equivalent — `buffer()` and `conflate()` are the two knobs, and they mean
   what they mean above.

## Testing

```kotlin
@Test
fun `emits loading then content`() = runTest {
    viewModel.state.test {
        assertEquals(OrdersUiState(isLoading = true), awaitItem())
        assertEquals(OrdersUiState(orders = twoOrders), awaitItem())
        cancelAndIgnoreRemainingEvents()
    }
}
```

1. **Turbine (`app.cash.turbine`) turns emissions into assertions.** `awaitItem()` per emission,
   `awaitComplete()` for a finite flow, `awaitError()` for a failing one — and the block fails on
   anything left unconsumed, which is the point.
2. **`expectNoEvents()` is how a negative is proved** — that a `debounce` swallowed the keystroke,
   that a `distinctUntilChanged` dropped the repeat. `skipItems(n)` walks past emissions the test
   does not care about, and `cancelAndIgnoreRemainingEvents()` ends a test of a flow that never
   completes.
3. **`turbineScope { }` for more than one flow at a time.** Inside it, `flow.testIn(backgroundScope)`
   gives a handle per flow, so state and effects can be asserted in one test in the order they
   actually happen.
4. **A `stateIn(WhileSubscribed)` flow does nothing until someone collects it.** Under `runTest`, a
   test that only reads `state.value` sees the initial value forever and reports a ViewModel that
   works as one that never loads. Either collect it — Turbine's `test { }` does, so does
   `backgroundScope.launch { state.collect { } }` — or build the subject on an
   `UnconfinedTestDispatcher` so the sharing coroutine starts eagerly. The dispatcher setup itself is
   `concurrency-coroutines`'s `## Testing`; the `MainDispatcherRule` body and the
   standard-versus-unconfined rule are in `arch-mvvm`'s reference, section `Test Setup`.
5. **Time-based operators run on virtual time like everything else.** `debounce` and `sample`
   complete instantly under `runTest`, and `awaitItem()` drives the scheduler on its own — reach for
   an explicit `advanceTimeBy` only when the assertion is about something other than an emission.

## Common Mistakes

1. **`MutableSharedFlow(replay = 0)` used for state.** Every collector that arrives after the
   emission gets nothing, so the screen is empty after a rotation and correct on a cold start — the
   hardest kind of bug to reproduce. State is a `StateFlow`; `replay = 0` is for what nobody may see
   twice.
2. **A `collect` inside another `collect`.** The inner collection never returns, so the outer flow's
   next value is never processed and the screen freezes on the first one. `flatMapLatest` if the
   outer value should restart the inner stream, `combine` if both are needed at once.
3. **`flowOn` written below the work it was meant to move.** `flowOn` changes the context of
   everything *above* it; placed at the bottom of the chain to "collect on `IO`" it changes nothing,
   because the terminal operator always runs in the collecting coroutine's context.
4. **`stateIn(Eagerly)` in a ViewModel over a database or a socket.** The upstream runs from
   construction to `onCleared()`, holding a cursor or a connection open for a screen sitting in the
   back stack. `WhileSubscribed(5_000)` costs one restart in the rare case and nothing in the common
   one.
5. **`MutableStateFlow` exposed as itself.** `val state = MutableStateFlow(…)` is a public setter:
   any collector can write the screen's state, and the ViewModel is no longer the only writer.
   `private val _state` plus `asStateFlow()`.
6. **`combine` with an input that has not emitted yet.** It produces nothing until every source has
   emitted once, so one flow waiting on a slow request pins the whole screen at its initial value.
   Give that source a start — `onStart { emit(default) }` — or make it nullable and model the gap.
7. **`catch` placed above the operator it should guard.** It only sees upstream exceptions, so a
   `catch` before the `map` that throws never runs, and the crash reaches the collector unchanged.
   It also never catches the collector's own body.
8. **`buffer` where `conflate` was meant.** `buffer` keeps every value and lets a slow collector fall
   behind by a growing queue; `conflate` keeps only the newest and drops the rest. A UI wants
   `conflate`; work nobody may lose wants `buffer` — and reaching for either to make something faster
   is the third mistake, since neither adds parallelism.
9. **`first()` on a `SharedFlow` with no replay.** It suspends until the *next* emission, and if the
   producer emitted before this collector arrived, there may not be one. `first()` is for a cold flow
   or a `StateFlow`.
10. **Two collectors on one cold flow.** Each collection runs the builder again: two queries, two
    sockets, two token refreshes, and two sets of results that disagree. Share it once, at the owner
    — the same one-per-query rule `persistence-architecture` states over a database `Flow`.
11. **`awaitComplete()` on a `StateFlow` in a test.** It never completes, so the test hangs until the
    timeout and the failure names Turbine rather than the flow. End with
    `cancelAndIgnoreRemainingEvents()`.
