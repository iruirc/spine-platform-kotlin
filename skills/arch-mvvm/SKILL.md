---
name: arch-mvvm
description: "Use when implementing MVVM in a Kotlin UI project — Android, Compose Desktop or Compose Multiplatform. Covers ViewModel design with StateFlow, modelling UiState (sealed interface vs data class), event handling (single onEvent vs named functions), one-shot effects, lifecycle-aware collection, the navigation boundary, and testing with Turbine and test dispatchers."
---

# MVVM in Kotlin

One ViewModel per screen owns that screen's state as a `StateFlow`; the composable renders it and
sends events back. This skill decides the **shape** of that state, where one-shot effects go, and
how the pair is tested. Where state lives *inside* the composable — hoisting, `remember`, state
holders — is `compose-state`; the route graph the screen is registered in is `nav-compose`.

> **Related skills:**
> - `compose-state` — hoisting, `remember` vs `rememberSaveable`, stability and recomposition below the ViewModel
> - `nav-compose` — the route graph the Screen sits in, and where its navigation lambdas come from
> - `arch-mvi` — when one screen's state machine outgrows ad-hoc `update {}` calls and earns a reducer
> - `arch-clean` — when the ViewModel starts orchestrating repositories and needs use cases under it
> - `di-hilt` — `@HiltViewModel`, assisted injection and `hiltViewModel()` on Android
> - `di-koin` — `viewModelOf` and the KMP, Compose Desktop and Ktor track
> - `concurrency-coroutines` — dispatcher per layer, `viewModelScope` ownership, cancellation discipline
> - `reactive-flow` — `stateIn` / `shareIn` started policies, `StateFlow` vs `SharedFlow`, Turbine
> - `error-architecture` — what a failed load becomes before it reaches `UiState.Error`
> - `architecture-choice` — the compass that sends you here, and the signals that send you elsewhere

## When to Use

- The active project guidance file's `## Stack` names `MVVM`, or `architecture-choice` just landed there
- A new Compose screen needs state that outlives recomposition and survives configuration change
- User asks "where does this logic go", "how do I model loading and error", "how do I navigate from
  a ViewModel", "sealed class or data class for the state"
- A composable has grown a repository call, a `try/catch` and three `remember`s inside it

Not for a screen with no asynchronous work and no state beyond one field — hoist it into the caller
and stop (`compose-state`). Not for a JVM server or CLI — that is `arch-layered`.

`references/detailed-guide.md` lies beside this file; its `## Contents` names the sections — read only the ones the table points to.

## When To Load The Reference

| Need | Reference sections |
|---|---|
| The domain, formatter and fake every example shares | `Shared Pieces` |
| A screen whose states are mutually exclusive | `Sealed UiState — ViewModel`, `Sealed UiState — Screen`, `Sealed UiState — Test` |
| A screen that keeps content while refreshing | `Data-class UiState — ViewModel`, `Data-class UiState — Screen`, `Data-class UiState — Test` |
| The shape most real screens land on | `Hybrid UiState` |
| Navigation and snackbar plumbing end to end | `One-shot Effects` |
| `Dispatchers.setMain`, Turbine, fakes, KMP test setup | `Test Setup` |

## Structure

One folder per screen, named after the screen:

```
feature/orders/
├── OrdersScreen.kt      # @Composable: collects state, renders, forwards events
├── OrdersViewModel.kt   # owns the MutableStateFlow, calls the domain
├── OrdersUiState.kt     # what the screen renders
└── OrdersUiEvent.kt     # what the user can do (no such file if you use named functions)
```

On KMP all four live in `commonMain`: `androidx.lifecycle.ViewModel` and `viewModelScope` are
multiplatform since Lifecycle 2.8, so no expect/actual is needed. For a small screen the state and
event types may share a file with the screen: `arch-clean` → "Packages and Files".

## ViewModel on Every Target

`androidx.lifecycle.ViewModel`, `viewModelScope` and `SavedStateHandle` are multiplatform, so the
screen's state holder is a `ViewModel` on Android, on Compose Desktop and in `commonMain` alike: one
class, no `expect`/`actual`, no second holder for the desktop. An `arch-mvi` store is the same class
with a reducer inside.

1. **Resolve it the same way everywhere** — `hiltViewModel()` on Android with Hilt, `koinViewModel()`
   on Desktop and KMP.
2. **On Compose Desktop the window is its owner.** Every Compose window is a `ViewModelStoreOwner`
   that clears its store when the window is disposed, and a navigation back-stack entry is an owner
   inside it exactly as on Android.

## Component Responsibilities

**Model** — domain entities, repositories, use cases. Plain Kotlin: `suspend` functions and `Flow`,
no `androidx.*`, no Compose. It must compile in a plain JVM test source set.

**ViewModel** — extends `androidx.lifecycle.ViewModel`. Owns the screen's one `UiState` and exposes
it as a `StateFlow` — from a private `MutableStateFlow`, or from a repository flow turned into state
with `stateIn` (Binding, below). Turns domain results into `UiState`: formatting, sorting, the
empty/error decision. Receives events, launches work in `viewModelScope`. Knows no composable, no
`Context`, no `NavController`.

**Screen** — `@Composable`, takes a `UiState` and an event lambda. Collects lifecycle-aware, renders,
forwards clicks. Owns only ephemeral UI state — scroll position, focus, expansion (`compose-state`).
Contains no `if (response.code == 401)` and no `repository.` call.

Split the screen in two composables: a `Route` that holds the ViewModel and resolves navigation, and
a stateless `Screen(state, onEvent)`. The stateless half is what previews and screenshot tests get.

## Modelling UiState

| Shape | Use when | Cost |
|---|---|---|
| `sealed interface UiState { Loading; Content(...); Error(...) }` | states are mutually exclusive and content is absent while loading | `when` exhaustiveness; no partial state |
| `data class UiState(isLoading, items, error)` | content persists across loading/error (pull-to-refresh, inline error) | invalid combinations must be prevented in the ViewModel |
| Both: `data class` with a `sealed` field for the mutually exclusive part | most real screens | one more type |

<!-- compile: jvm -->
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

Rules:

1. **One state type per screen.** Two parallel `StateFlow`s reintroduce exactly the invalid
   combinations the type was meant to forbid, and the composable now renders two arrival orders.
2. **`UiState` holds rendered values, not domain objects** — `total: String`, already formatted, not
   `Long` plus a formatter call in the composable.
3. **Skipping is decided where the ViewModel builds the state.** A list it rebuilds on every
   emission is what `compose-state` → "Stability" fixes, not the `List` type itself.
4. **Give a data-class shape defaults**, so a preview and a test can build it with `OrdersUiState()`.

## Events

Two styles. Pick one per project; never mix them.

| Style | Shape | Choose when |
|---|---|---|
| Named functions | `fun onRetry()`, `fun onOrderClick(id: OrderId)` | few actions; each carries its own arguments; call sites read as prose |
| Single sink | `fun onEvent(event: OrdersUiEvent)` over a `sealed interface` | many actions; one lambda in the Screen signature; every action passes one place for logging or analytics |

1. **Never mix.** A project doing both ends with the action list in two places and reviewers guessing
   which one a new action belongs in.
2. **The Screen takes lambdas, never the ViewModel.** `onEvent: (OrdersUiEvent) -> Unit`, or a small
   fixed set of named lambdas. A composable typed against `OrdersViewModel` cannot be previewed and
   cannot be tested without constructing one.
3. **Events name what happened in the UI** (`RetryClicked`), not what the ViewModel should do
   (`ReloadOrders`). That translation is the ViewModel's job and is where the logic lives.
4. **`data object` for argument-less events**, so equality holds and no emission allocates.

## One-shot Effects

**Prefer state. An effect is only for what cannot be re-rendered** — navigating away, a snackbar, a
share sheet, a haptic. Anything still true after a configuration change belongs in `UiState`.

| Mechanism | Delivery | Cost |
|---|---|---|
| `UiState` field + a `consumed()` event | survives process death behind `SavedStateHandle`; assertable with no collector | the state grows a field per effect, and the Screen must remember to consume |
| `Channel(Channel.BUFFERED)` + `receiveAsFlow()` | buffered while nothing collects; exactly one collector receives each item | a second collector steals items; nothing survives process death |
| `MutableSharedFlow(replay = 0, extraBufferCapacity = 1)` | many collectors | emitted with no collector means dropped, and the recreation gap is exactly that window |

1. **Default to `Channel` + `receiveAsFlow()`** for navigation and snackbars: one screen, one
   collector, buffered across the configuration-change gap — with one element's worth of risk, since
   `receiveAsFlow()` can take an item out of the channel just as collection is cancelled.
2. **A `UiState` field plus a consume event only for an effect that must survive process death** —
   a payment result, a finished wizard — written through `SavedStateHandle` and cleared by the event
   the Route sends once it has acted. For any other effect the field buys nothing and costs a consume
   call the Route must never forget: forget it and the effect fires again on the next return.
3. **Collect effects lifecycle-aware** — `viewModel.effects.flowWithLifecycle(lifecycle)`, not a bare
   `LaunchedEffect(Unit) { effects.collect { } }`, or a backgrounded screen navigates under the one
   the user is looking at.
4. **Never make a persistent error an effect.** A message dismissed by rotation is a bug the state
   shape would have prevented.
5. **One `sealed interface OrdersEffect` per screen**, so the Route's `when` stays exhaustive.

## Binding

```kotlin
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel

@Composable
fun OrdersRoute(
    onOpenOrder: (OrderId) -> Unit,
    viewModel: OrdersViewModel = hiltViewModel(),   // koinViewModel() on KMP/Desktop
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    OrdersScreen(state = state, onEvent = viewModel::onEvent)
}
```

1. **`collectAsStateWithLifecycle()` on Android and in `commonMain`**
   (`androidx.lifecycle:lifecycle-runtime-compose`, multiplatform since Lifecycle 2.8) — it stops
   collecting below `STARTED`. `collectAsState()` keeps a backgrounded screen re-rendering and keeps
   its upstream alive.
2. **The same collector on Compose Desktop.** The window is a lifecycle owner too (ViewModel on
   Every Target, above), so a desktop screen and a Compose Multiplatform screen in `commonMain` take
   `collectAsStateWithLifecycle()` like any Android screen.
3. **Derived flows are shared once, not re-collected per subscriber:**

```kotlin
val state: StateFlow<OrdersUiState> = repository.orders()
    .map(::toUiState)
    .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), OrdersUiState())
```

4. **`WhileSubscribed(5_000)`** — the five seconds spans a configuration change. `Eagerly` keeps
   upstream work running while the screen sits in the back stack; `Lazily` never stops it at all
   (`reactive-flow`).
5. **Collect once per screen, at the Route.** A composable deeper in the tree collecting its own flow
   makes one screen's render depend on two arrival orders.

## ViewModel Rules

1. **No Android framework import except `androidx.lifecycle`.** No `android.content.Context`, no
   `android.net.Uri`, no `androidx.compose.*`. Its tests are plain JVM tests or they are not tests.
2. **Dependencies by constructor** — repositories, use cases, a `SavedStateHandle`, and the
   dispatcher if the ViewModel names one. Nothing pulled from a service locator inside the body.
3. **`viewModelScope` only.** `GlobalScope` outlives the screen; a hand-made `CoroutineScope` has to
   be cancelled in `onCleared()` and reliably is not.
4. **No `Context`.** Strings resolve in the composable; the ViewModel emits a resource id or a typed
   message (`error-architecture`). A ViewModel that formats a localized string needs a device to test.
5. **`SavedStateHandle` for anything that must survive process death** — route arguments, a search
   query, a wizard step. A `MutableStateFlow` survives configuration change, not process death.
6. **Mutable state stays private** — `private val _state` plus `val state = _state.asStateFlow()`.
7. **One ViewModel per route**, not per composable; a graph-scoped one only when the graph really is
   the lifetime (`nav-compose`).
8. **No work started from `init`** unless it is `stateIn(WhileSubscribed)`. See Mistake 8.

## Navigation Boundary

What a ViewModel may do about navigation is `nav-compose` → "The Boundary"; its side of it is one
more member of the screen's effect type, carried as One-shot Effects above describes.

## Testing ViewModel

<!-- compile: jvm-test -->
```kotlin
@ExtendWith(MainDispatcherExtension::class)
class OrdersViewModelTest {
    @Test
    @DisplayName("retry after a failure loads the orders")
    fun onEvent_retryAfterFailure_loadsOrders() = runTest {
        val repository = FakeOrderRepository().apply { failWith(IOException()) }
        val viewModel = OrdersViewModel(repository, money)

        viewModel.state.test {
            assertEquals(OrdersUiState(), awaitItem())
            viewModel.onEvent(OrdersUiEvent.Appeared)
            assertEquals(OrdersUiState.Content.Failed(UiMessage.Offline), awaitItem().content)

            repository.succeedWith(listOf(beans))
            viewModel.onEvent(OrdersUiEvent.RetryClicked)
            assertEquals(OrdersUiState.Content.Loading, awaitItem().content)
            assertEquals(1, (awaitItem().content as OrdersUiState.Content.Loaded).orders.size)
            cancelAndIgnoreRemainingEvents()
        }
    }
}
```

1. **`StandardTestDispatcher` as `Main`, and `UnconfinedTestDispatcher` never to turn a test green.**
   Queued coroutines make the intermediate `Loading` observable; the unconfined one runs eagerly, the
   test never sees it, and it passes by covering less.
2. **Replace `Dispatchers.Main` with the hook of the file's framework.** `viewModelScope` runs on
   `Dispatchers.Main.immediate` and offers no other seam; the sample is JUnit5:
   `test-frameworks` → "Main Dispatcher in Tests"
3. **A `stateIn(WhileSubscribed)` state gets a collector, not another dispatcher.** With no
   subscriber the sharing coroutine never collects upstream, on any dispatcher, and `state.value`
   stays initial. Turbine's `test { }` is a collector; a test that asserts `state.value` starts
   `backgroundScope.launch { viewModel.state.collect() }` and then calls `advanceUntilIdle()`.
4. **Turbine (`.test { }`) for transitions**, a plain `assertEquals` on `state.value` only when a
   single settled value is the whole assertion.
5. **Fakes over mocks.** A fake repository with a settable result reads better than four stubbing
   lines and does not pin the test to a call order the ViewModel is free to change.
6. **Assert effects too** — `viewModel.effects.test { … }`. An unasserted `Channel` is where a
   navigation bug hides.
7. **If the ViewModel takes a dispatcher, inject `StandardTestDispatcher()` from the same
   `runTest` scheduler**, or `advanceUntilIdle()` will not reach the work.

## When Appropriate

- Any Compose screen with asynchronous state — Android, Compose Desktop, Compose Multiplatform
- Solo to three developers, months to years: the default the compass lands on for a Compose app
- Logic worth a unit test, but not yet worth a domain layer or its own module

Skip it when the screen is purely presentational (a stateless composable and a parameter is the whole
design), or when the target has no UI at all.

## When to Add Clean

MVVM stops paying at the ViewModel's edges, not inside them. Add use cases and a domain layer
(`arch-clean`) when two or more of these hold:

- One ViewModel orchestrates three or more repositories
- The same business rule is written out in two ViewModels
- The rules must be testable with no `androidx.*` on the classpath at all
- Android and iOS have to share the rule, so it must move to `commonMain` (`pkg-kmp-source-sets`)
- The ViewModel passes ~300 lines and the top third of the file is mapping

If instead the pain is one screen's state machine — many events, order-dependent transitions,
"which state are we even in" — that is `arch-mvi`, not `arch-clean`. Layering and reducers fix
different problems, and adding both at once fixes neither.

## Common Mistakes

1. **`collectAsState()` on a screen** — the screen keeps collecting in the back stack and behind
   a locked screen, holding its upstream open and recomposing off-screen. Use
   `collectAsStateWithLifecycle()` on every target, Compose Desktop included (Binding, above).
2. **Business logic in the composable** — a `try/catch` around a repository call inside
   `LaunchedEffect`, or `if (user.isPremium && cart.total > 100)` in the render. Recomposition runs
   it an unpredictable number of times, and no unit test can reach it.
3. **`MutableStateFlow` exposed** — a public `val state = MutableStateFlow(...)`. Any composable can
   now write the screen's state, and the single-writer guarantee the shape promised is gone. Expose
   `.asStateFlow()`.
4. **`GlobalScope.launch`** — work that outlives the screen, ignores cancellation and leaks the
   ViewModel with it. `viewModelScope` is cancelled in `onCleared()`; nothing else is.
5. **Navigating from the ViewModel through a `NavController` reference** — `nav-compose` → "The Boundary".
6. **`LiveData` in new code** — Android-only, no operators worth the name, and untestable outside
   instrumentation without an extra rule. `StateFlow` works on all three targets; convert `LiveData`
   as you touch it (`reactive-flow`).
7. **`viewModelScope.launch { repository.load() }` with no error handling** — one thrown exception
   and the screen sits on `Loading` forever with no way back. Wrap the call in `catching` and map
   the failure into the state: `error-architecture` → "The runCatching Rule".
8. **`init { load() }`** — the constructor does I/O, so every test must arrange every dependency
   before the ViewModel exists, and the load can never be repeated, which is why such screens grow a
   second undocumented reload path. Use `stateIn(WhileSubscribed)`, or an explicit event the Route
   sends on first composition.
9. **Mixing event styles** — `onEvent(UiEvent)` for half the screen and `onRetry()` for the rest.
   One style per project (see Events).
10. **A `UiState` that can be wrong** — `isLoading = true` together with `error != null`, because
    three independent fields have eight combinations and the screen renders four of them. Make the
    mutually exclusive part a sealed type: row three of the table above.
