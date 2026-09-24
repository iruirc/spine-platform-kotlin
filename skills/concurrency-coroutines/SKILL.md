---
name: concurrency-coroutines
description: "Use when placing coroutines across layers in a Kotlin project — which dispatcher each layer uses, which scope owns which work (viewModelScope, lifecycleScope, an app scope, a request scope), SupervisorJob, cancellation and CancellationException discipline, withContext placement, fan-out with coroutineScope/async at the right layer, Mutex, Flow lifecycle, server-side dispatchers vs virtual threads and Reactor interop, and testing with kotlinx-coroutines-test."
---

# Coroutines Across the Layers

Where a coroutine runs, who owns it, and what happens to it when the thing that started it goes
away — decided once per layer instead of once per call site. Flow *operators* and sharing policies
(`stateIn`, `shareIn`, `StateFlow` vs `SharedFlow`) are `reactive-flow`; this skill covers only a
flow's **lifecycle**: which scope collects it and what cancels the collection.

> **Related skills:**
> - `reactive-flow` — operators, `stateIn` / `shareIn` started policies, `StateFlow` vs `SharedFlow`, Turbine
> - `arch-mvvm` — `viewModelScope` ownership, the dispatcher a ViewModel may be given, lifecycle-aware collection
> - `arch-mvi` — the same ownership when a reducer, not an `update {}` call, is the only writer
> - `arch-clean` — why a use case names no dispatcher, and the layer that composes two repositories
> - `arch-layered` — the service method that is the transaction boundary a suspending call runs inside
> - `net-architecture` — the request that dies with its scope, and single-flight refresh behind a `Mutex`
> - `persistence-architecture` — `Dispatchers.IO` as a `:data` word, Room's executor vs SQLDelight's caller thread
> - `error-architecture` — the `catching` helper, the `runCatching` trap, and what a cancellation must never be mapped to
> - `compose-state` — `LaunchedEffect` and `rememberCoroutineScope()`, the two composition-scoped starters
> - `di-composition-root` — the app scope this skill hands work to, and why bootstrap never blocks

## When to Use

- A new layer is being written and nobody has said which dispatcher it runs on
- User asks "where does `withContext` go", "why does my screen freeze", "why is this still running
  after I pressed Back", "`coroutineScope` or `supervisorScope`", "`GlobalScope` — is that bad",
  "how do I test a coroutine", "coroutines or virtual threads on the server"
- Review finds `withContext(Dispatchers.IO)` in a ViewModel or a use case, a `runCatching` around a
  suspending call, a `GlobalScope.launch`, or a `runBlocking` outside `main()` and tests
- A crash report shows work writing into a screen that is already gone
- A server thread pool saturates under load while every metric still reads healthy

Not for choosing between `Flow`, `StateFlow` and `SharedFlow` or for operator chains — that is
`reactive-flow`. Not for what a failed call becomes before the user sees it — `error-architecture`.
Not for which HTTP client suspends how — `net-http-clients`.

`references/detailed-guide.md` lies beside this file; its `## Contents` names the sections — read only the ones the table points to.

## When To Load The Reference

| Need | Reference sections |
|---|---|
| The shared `Order` type every section uses, and the client/server sample convention | `Shared Type` |
| A ViewModel → use case → repository → data source chain with the one `withContext` in it | `The Chain — Where withContext Sits` |
| A CPU loop that stays cancellable, and cleanup that still runs after cancel | `Cancellation — ensureActive in a Loop`, `Cancellation — Cleanup Under NonCancellable` |
| Deadlines that throw versus deadlines that return null | `Cancellation — withTimeout and withTimeoutOrNull` |
| Two independent loads in one use case, and the variant where one may fail alone | `Fan-out — coroutineScope and async`, `Fan-out — supervisorScope and Per-Child Failure` |
| A background owner that survives every screen, on desktop/server and on Android | `App Scope — A Service That Outlives the Screen`, `Android — WorkManager CoroutineWorker` |
| A counter two coroutines write, and a bounded pool over a blocking driver | `Shared State — Mutex`, `Shared State — limitedParallelism for Blocking JDBC` |
| Suspending handlers per server framework, and the Reactor bridges | `Server — Ktor Handlers`, `Server — Spring WebFlux and Reactor Interop`, `Server — Spring MVC and Virtual Threads` |
| Virtual time, an injected dispatcher under test, a collector that never ends | `Testing — runTest and Virtual Time`, `Testing — Injected Dispatchers and setMain`, `Testing — backgroundScope for Endless Collectors` |

## Why This Skill Exists

Every layer answers its own coroutine question locally, and the answers stop agreeing. The same five
failure modes, every time:

- **`withContext(Dispatchers.IO)` at every level.** The ViewModel wraps the use case, the use case
  wraps the repository, the repository wraps the DAO — four switches to reach a call Room had
  already moved off the main thread, and nobody can say which one is load-bearing.
- **`withContext` nowhere.** The data source is a blocking `File.readText()` reached from
  `viewModelScope`, and the screen drops frames on a device slower than the reviewer's.
- **Work owned by nobody.** `GlobalScope.launch { }` because the compiler wanted a scope. The screen
  dies, the request finishes, the result is written into a cleared ViewModel — or, worse, the work
  keeps running for the rest of the process.
- **Cancellation caught as failure.** A `runCatching` in the repository turns a Back press into
  `UiState.Error`, and nothing rethrew, so the cancelled coroutine keeps going.
- **One failure taking down the wrong tree.** A background refresh started on a shared scope with a
  plain `Job` throws, and every other coroutine on that scope dies with it, permanently.

The fix is three decisions, made once: **the dispatcher belongs where the blocking is, the scope
belongs to whatever owns the lifetime, and cancellation is never caught — only rethrown.**

## Per-Layer Dispatchers

| Layer | Runs on | Decided by |
|---|---|---|
| Composable | the composition's context — `LaunchedEffect`, `rememberCoroutineScope()` | Compose (`compose-state`) |
| ViewModel | `Dispatchers.Main.immediate`, which is what `viewModelScope` is built from | the framework; the ViewModel adds nothing |
| Use case | the caller's context; it names no dispatcher at all | `arch-clean` |
| Repository | the caller's context; it composes sources and maps, it does not switch | `persistence-architecture` |
| Data source, network | the client's own machinery — Retrofit and Ktor suspend without holding a thread | `net-http-clients` |
| Data source, local database or files | `withContext(Dispatchers.IO)` around the blocking part | **this is the one place the switch belongs** |
| Heavy mapping, parsing, crypto | `withContext(Dispatchers.Default)` where the work is | the source doing the work |
| Server route or controller | the engine's dispatcher — Ktor's, or Reactor's under WebFlux | the framework |
| Server service | the caller's context; it owns the transaction boundary, not the dispatcher | `arch-layered` |
| Server repository over blocking JDBC | `Dispatchers.IO.limitedParallelism(n)` sized to the pool, or virtual threads | `## On the Server` |
| App-scoped background service | its own scope's dispatcher, usually `Dispatchers.Default` | `di-composition-root` |

1. **`withContext` goes where the blocking actually happens, and nowhere above it.** Main-safety is
   the data layer's contract: a `suspend` function is safe to call from any dispatcher, and making
   that true is the callee's job. `arch-clean` bars the use case from naming a dispatcher and
   `persistence-architecture` bars the ViewModel from wrapping a repository call; both hold for one
   reason, which is that neither layer can see what the call beneath it actually costs.
2. **Three dispatchers, three jobs.** `Dispatchers.Default` for CPU — a pool sized to the core
   count. `Dispatchers.IO` for calls that block a thread — elastic, limited to 64 threads or the
   processor count, whichever is larger, and sharing its threads with `Default`, so switching
   between the two is often not a thread hop at all. `Dispatchers.IO.limitedParallelism(n)` when a
   resource has a real ceiling: a connection pool, a device, a rate limit.
3. **Inject the dispatcher; do not hard-code it inside the method.** A constructor parameter
   defaulting to `Dispatchers.IO` is replaced in one line under test; a literal buried in a function
   body makes every test of it depend on real thread scheduling.
4. **A dispatcher is not a scope.** `Dispatchers.IO` says *which thread*; a scope says *how long*.
   Passing a dispatcher where a lifetime was needed is how work ends up outliving its owner.
5. **Never `withContext(Dispatchers.Main)` to publish state.** The ViewModel is already there —
   `viewModelScope` runs on `Dispatchers.Main.immediate`, and a `StateFlow` is safe to write from
   anywhere anyway. The wrapper is a leftover from a callback API.

## Scope Ownership

Every coroutine belongs to exactly one scope, and that scope's lifetime is the answer to "when does
this stop".

| Scope | Lifetime | Use for | Cancelled by |
|---|---|---|---|
| `viewModelScope` | the ViewModel | everything a screen does (`arch-mvvm`) | `onCleared()` |
| `lifecycleScope` + `repeatOnLifecycle(STARTED)` | the Android host, restarted per visibility | collecting a flow into a View or Fragment | `STOPPED`, then relaunched |
| `rememberCoroutineScope()` | the composition | work started from a callback — a click, a swipe | leaving the composition |
| application scope, held in the graph | the process | uploads, sync, the shared token refresh | shutdown, or nothing |
| request scope (Ktor `call`, WebFlux request) | one request | everything a handler does | client disconnect, timeout |
| `GlobalScope` | the process, with no owner | **nothing** | never |

1. **Pick the narrowest scope that outlives the result.** If the result is only ever rendered into a
   screen, the screen's scope is correct and the cancellation is free.
2. **`GlobalScope` is never the answer**, because it is not an owner: no cancellation, no exception
   handler, no test seam. Everything it is reached for — a fire-and-forget upload, a log flush — is
   an application-scoped `CoroutineScope` in the composition root instead, injected like any other
   dependency (`di-composition-root`).
3. **An application scope is `SupervisorJob() + Dispatchers.Default + CoroutineExceptionHandler`.**
   `SupervisorJob` so one failed child does not cancel its siblings; the handler so an uncaught
   throw is logged rather than silently swallowed by a scope nobody awaits.
4. **A `CoroutineExceptionHandler` only works on a root scope.** Installed on a child `launch`, or
   on an `async`, it is ignored — the exception goes to the parent. Put it in the scope's context,
   once.
5. **Flow collection is scope-bound like anything else.** Collect in `repeatOnLifecycle(STARTED)`
   on Views, or with `collectAsStateWithLifecycle()` in Compose, so a backgrounded screen stops the
   upstream (`arch-mvvm`). What the upstream does meanwhile is a `stateIn` policy (`reactive-flow`).
6. **`launch` versus `async`.** `launch` reports failure to its parent immediately; `async` produces
   a value and holds its exception until `await()`, so one nobody awaits is a lost exception.

## Cancellation

Cancellation is cooperative: it sets a flag and makes the *next* suspension point throw
`CancellationException`. Three rules keep the chain intact.

**1. A `catch` around a suspending call never keeps `CancellationException`.**

`error-architecture` → "The runCatching Rule"

Every `catching` in this skill and its reference is the helper that section owns.

**2. A loop with no suspension point is not cancellable — call `ensureActive()` or `yield()`.**

```kotlin
suspend fun parse(rows: List<RawRow>): List<Row> = withContext(Dispatchers.Default) {
    rows.map { row ->
        ensureActive()          // cheap check; throws if the caller gave up
        expensiveParse(row)
    }
}
```

`ensureActive()` only checks. `yield()` also offers the thread to other coroutines, which matters
when the loop monopolises a `Default` thread. Every `suspend` call already checks, so a loop that
awaits something needs neither.

**3. `NonCancellable` is for cleanup in `finally`, and nothing else.**

```kotlin
try {
    upload(file)
} finally {
    withContext(NonCancellable) { tempFile.delete() }   // suspending cleanup after cancel
}
```

A cancelled coroutine's `finally` runs, but every suspending call inside it throws immediately, so a
suspending release, rollback or final log line needs `withContext(NonCancellable)`. Wrapping
business work in it makes an uncancellable coroutine — the bug it looks like a fix for.

Two shapes built on the same mechanism: **`coroutineScope { }` fails together** — one child's
exception cancels its siblings and the whole block throws — while **`supervisorScope { }` isolates
children**, so a failed child is that child's problem. `withTimeout` cancels the block and throws
`TimeoutCancellationException`; `withTimeoutOrNull` returns `null` instead. Neither belongs in a
repository: a deadline is a business decision (`net-architecture` splits it from the client's
transport timeouts).

## Fan-out Placement

The question is never "should this be parallel" but "**which layer knows that these calls belong
together?**"

| Situation | Layer | Construct |
|---|---|---|
| A screen means profile + orders + unread count, fixed set | use case | `coroutineScope { async … }` |
| N independent items, count known at runtime | use case | `coroutineScope` + `map { async { } }` + `awaitAll()` |
| Each piece renders as it arrives, no business meaning | ViewModel | `viewModelScope.launch` per piece |
| One piece may fail without failing the screen | use case | `supervisorScope` + per-child `catching` on the `await` |
| Two sources merged into one stream | repository | flow operators (`reactive-flow`) |
| Prefetch on app start | app-scoped service | its own scope |

```kotlin
class LoadDashboard(
    private val profiles: ProfileRepository,
    private val orders: OrderRepository,
) {
    suspend operator fun invoke(userId: UserId): Dashboard = coroutineScope {
        val profile = async { profiles.byId(userId) }
        val recent = async { orders.recent(userId) }
        Dashboard(profile.await(), recent.await())
    }
}
```

1. **Fan-out in the use case when the parallelism *is* the business operation.** "Opening the
   dashboard means fetching three things" is a domain fact, and it is testable without a screen.
2. **Fan-out in the ViewModel when it is pure UI choreography.** Three thumbnails that each appear
   when ready is a rendering decision, not a domain one.
3. **Never in a repository.** A repository that assembles a screen-shaped object has taken a
   presentation concept into `:data`, and the use case left above it shrinks to one forwarding line
   (`arch-clean`).
4. **`coroutineScope` is the default; `supervisorScope` is the exception you can name.** If you
   cannot say which child may fail alone and what the screen shows instead, you want everything to
   fail together — and the per-child wrapper is `catching`, because `await()` suspends.
5. **Two sequential `await()` calls are not sequential work.** `async { }` starts immediately, so
   `a.await()` then `b.await()` still overlaps — while `async { }.await()` on one line does not.

## Shared State

**`Mutex` is the default when two coroutines write the same thing.** `mutex.withLock { }` suspends
rather than blocking a thread, which is the whole reason not to reach for `synchronized` here — and
it is not reentrant, so a locked section calling another locked section on the same `Mutex`
deadlocks. Keep the critical section to the mutation; never do I/O inside it.

**Confinement beats locking when it is available.** State owned by exactly one coroutine — a
ViewModel's fields written only from `viewModelScope`, a server component that mutates only inside
one request — needs no lock, because there is one writer by construction.

**`StateFlow.update { }` is the right tool for state that is also observed.** It is an atomic
compare-and-set loop, so two concurrent updates cannot lose one, and readers get the result without
a lock. `value = value.copy(...)` is the read-modify-write that loses the update; the fact that it
compiles identically at a glance is why this appears in review so often.

**`AtomicReference`, `AtomicInteger` and friends are for one independent value** — a counter, a
flag, a cached token — with nothing to observe and nothing to stay consistent with. The moment two
atomics must agree, they are one state object behind a `Mutex` or in a `StateFlow`.

## Background Work That Outlives the Screen

Work that must finish after the user navigates away does not need a wider *cancellation* rule; it
needs a **wider owner**.

| Work | Owner | Target |
|---|---|---|
| Deferrable and guaranteed — sync, upload retry, cleanup | `WorkManager` `CoroutineWorker` | Android |
| User-visible and ongoing — playback, navigation, a live recording | a foreground service | Android |
| Fire-and-forget for the process lifetime — analytics flush, cache warm | app-scoped `CoroutineScope` in the graph | any |
| Long, cancellable, and the caller may want it back | a service method returning the `Job` | any |
| Per-request only | the request scope | server |

1. **On Android, "must survive the process" means `WorkManager`.** An app-scoped `CoroutineScope`
   dies with the process, and the system kills backgrounded processes without asking.
   `CoroutineWorker.doWork()` is `suspend`, runs on `Dispatchers.Default` unless `coroutineContext`
   is overridden, and returns `Result.retry()` for the framework to reschedule.
2. **On desktop and the server, the app-scoped service is the answer** — one
   `CoroutineScope(SupervisorJob() + Dispatchers.Default + handler)` created in the composition root
   and cancelled on shutdown (`di-composition-root`).
3. **Starting the work and owning it are two different jobs.** A ViewModel that calls
   `uploader.enqueue(file)` has handed ownership over and may navigate away; one that writes
   `viewModelScope.launch { upload(file) }` kept it, and navigating away kills the upload mid-body.
4. **Hand the `Job` back when the caller may need to stop it.** A service that returns
   `Job` from `start()` lets a screen cancel what it started without owning the scope it runs in.
5. **Bootstrap is not background work.** `runBlocking { }` in `Application.onCreate` or in a Spring
   bean's constructor is a frozen start-up, not a coroutine question (`di-composition-root`).

## On the Server

1. **A handler is `suspend` and runs on the framework's dispatcher.** Ktor routes are `suspend` on
   the engine's dispatcher and carry the call's `Job`, so a disconnect cancels the handler. Spring
   WebFlux supports `suspend` controller methods and `Flow<T>` return types when
   `kotlinx-coroutines-reactor` is on the classpath — the flow is adapted to a reactive stream and
   streamed to the client.
2. **Spring MVC also takes `suspend` controller methods**, through the same
   `kotlinx-coroutines-reactor` bridge and only when it is on the classpath — the handler is adapted
   and the servlet request is handled asynchronously. It is not WebFlux, and the rest of the MVC
   stack below it is still blocking.
3. **Blocking JDBC gets a bounded dispatcher.** `Dispatchers.IO.limitedParallelism(n)` with `n`
   matched to the connection pool: more coroutines than connections only queues them somewhere less
   observable. Under Exposed, `newSuspendedTransaction(Dispatchers.IO)` (`persistence-jvm-orm`).
4. **Virtual threads change the cost, not the model.** With `spring.threads.virtual.enabled=true`,
   or a dispatcher built from `Executors.newVirtualThreadPerTaskExecutor().asCoroutineDispatcher()`,
   a blocking call parks a virtual thread instead of a platform one, so `Dispatchers.IO`'s thread
   limit stops being the constraint and `limitedParallelism` is no longer needed *for thread
   economy*. It is still
   needed for anything with a real ceiling — a connection pool is still finite. Before JDK 24 a
   virtual thread that blocks inside `synchronized` pins its carrier, which is exactly where old
   JDBC drivers block; `ReentrantLock` does not pin.
5. **Reactor interop is three functions.** `mono { }` wraps a suspending block into a `Mono`;
   `awaitSingle()` / `awaitSingleOrNull()` / `awaitFirstOrNull()` consume a publisher from a
   suspending function; `asFlow()` and `asPublisher()` convert streams. Convert once, at the edge.
6. **`runBlocking` belongs in `main()`, in tests, and in a blocking callback you do not control** —
   an OkHttp `Interceptor` or `Authenticator` (`net-http-clients`). On a request thread it hands
   back the thread pooling the framework just gave you.
7. **Cancellation on the server means a disconnect.** Ktor cancels the call's `Job` when the client
   goes away — true only if nothing in the chain swallowed the `CancellationException`.

## Testing

1. **`runTest { }` is the entry point, and it runs on virtual time.** `delay(10.minutes)` completes
   instantly; a test that actually takes ten minutes is one that escaped the test scheduler.
2. **Every dispatcher under test comes from the same `testScheduler`.** A dispatcher built on any
   other scheduler is one `advanceUntilIdle()` never reaches, and the test hangs or flakes.
3. **`StandardTestDispatcher` queues; `UnconfinedTestDispatcher` runs eagerly.** Default to the
   first: ordering is explicit, and `advanceUntilIdle()` / `runCurrent()` say when work may proceed.
   Reach for the second only when the intermediate states do not matter (`arch-mvvm`).
4. **On Android, `Dispatchers.setMain` is the only seam for `viewModelScope`.** Install it through a
   JUnit rule and reset it after; `arch-mvvm`'s reference carries the rule body, and it is not
   repeated here.
5. **A collector that never ends goes on `backgroundScope`.** `runTest` waits for its own children,
   so `launch { flow.collect { } }` in the test body hangs forever.
6. **Test cancellation explicitly.** Cancel the `Job`, then assert the effect — request aborted,
   cleanup ran, no state written. That bug is invisible in a test that runs to completion. Flow
   assertions themselves are Turbine's job, and `reactive-flow` owns that setup.

## Common Mistakes

1. **`withContext(Dispatchers.IO)` in a ViewModel or a use case.** It moves a decision about where
   blocking happens up into a layer that cannot know. The repository call is already main-safe or it
   is a bug in the repository (`arch-clean`, `persistence-architecture`).
2. **`runCatching` around a suspending call.** A cancelled coroutine reports a failure to the user
   and keeps running:
   `error-architecture` → "The runCatching Rule".
3. **`GlobalScope.launch { }`.** No owner, no cancellation, no exception handler, no test seam. An
   application-scoped `CoroutineScope` from the graph does the same job and can be stopped.
4. **`value = value.copy(...)` on a `StateFlow` from two coroutines.** A read-modify-write that
   silently drops one update. `update { }` is the atomic form and is the same length.
5. **A `CoroutineExceptionHandler` on a child coroutine.** Installed on a `launch` inside a scope, or
   on any `async`, it does nothing — the exception propagates to the parent. It only takes effect in
   a root scope's context.
6. **A shared scope built on a plain `Job`.** The first uncaught failure cancels the scope, and every
   later `launch` on it returns an already-cancelled `Job`. Shared scopes are `SupervisorJob`.
7. **A CPU loop with no `ensureActive()`.** Cancellation is cooperative: a loop that never suspends
   runs to the end after the screen is gone, holding a `Default` thread while it does.
8. **`withContext(NonCancellable)` around real work.** It was reached for because "the write kept
   getting cancelled", and it produces a coroutine that cannot be stopped at all. It is for
   suspending cleanup in `finally`, and the block should be two lines.
9. **Fan-out inside a repository.** The repository returns a screen-shaped object, the use case has
    nothing left to do, and the parallelism cannot be changed without touching `:data`.
10. **`runBlocking` outside `main()`, tests and blocking callbacks.** On Android's main thread it is
    an ANR; on a server thread it hands back the thread the framework had pooled for you. Reached
    for during graph construction, it is the bootstrap mistake `di-composition-root` names.
11. **A screen-scoped upload.** `viewModelScope.launch { upload(photo) }` followed by navigation
    cancels the upload mid-body. The work needs a longer-lived owner, not a wider `try`.
12. **Collecting a flow in `lifecycleScope.launch` without `repeatOnLifecycle`.** The collection
    survives backgrounding and holds the upstream — a cursor, a socket — open behind it
    (`arch-mvvm`).
13. **A test dispatcher built on its own scheduler.** `StandardTestDispatcher()` passed in while
    `runTest` drives a different one: `advanceUntilIdle()` never reaches it, and the test hangs,
    times out, or passes for the wrong reason.

## Quick Reference

| Situation | Construct | Where |
|---|---|---|
| a blocking call | `withContext(Dispatchers.IO)` | the data source, never above it |
| heavy CPU work | `withContext(Dispatchers.Default)` | where the work is |
| two independent loads that belong together | `coroutineScope { async … }` | the use case |
| one of them may fail alone | `supervisorScope` + `catching` on the `await` | the use case |
| a loop that may run long | `ensureActive()` (or `yield()`) | inside the loop |
| cleanup after a cancel | `withContext(NonCancellable)` in `finally` | where the resource is |
| a deadline a human is waiting on | `withTimeout` / `withTimeoutOrNull` | the use case |
| shared mutable counter | `Mutex.withLock` or `StateFlow.update` | the owner |
| screen work | `viewModelScope` | the ViewModel |
| work that must survive the screen | `WorkManager` (Android) or the app scope | the graph |
| blocking JDBC on a server | `Dispatchers.IO.limitedParallelism(n)`, or virtual threads | the repository |
| bridging a `Mono` or a `Flux` | `mono { }`, `awaitSingle()`, `asFlow()` | the adapter edge |
| test with virtual time | `runTest` + `advanceUntilIdle()` | the test |
