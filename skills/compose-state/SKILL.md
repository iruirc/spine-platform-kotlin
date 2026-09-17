---
name: compose-state
description: "Use when deciding where state lives in a Compose UI — Android, Desktop or Multiplatform. Covers the hoisting decision, remember vs rememberSaveable vs ViewModel, state holders, stability and the strong-skipping mode, side-effect handlers, derived state, and diagnosing recomposition."
---

# Compose State

Everything below the ViewModel: which composable owns a piece of state, how far up it is hoisted,
what survives rotation, and why a screen recomposes more than it should. The state the ViewModel
itself owns — the `UiState` type, one-shot effects, lifecycle-aware collection — belongs to
`arch-mvvm` (or `arch-mvi`) and is not repeated here.

> **Related skills:**
> - `arch-mvvm` — the ViewModel above this boundary: `UiState` shape, one-shot effects, lifecycle-aware collection
> - `arch-mvi` — the same boundary when a reducer, not an `update {}` call, owns the screen's state
> - `nav-compose` — the back stack entry that scopes a ViewModel, and what a route argument may carry
> - `nav-multiplatform` — preserving state across Android, iOS and desktop under Decompose or Voyager
> - `reactive-flow` — `StateFlow` vs `SharedFlow` and the `stateIn` started policies feeding the collector
> - `concurrency-coroutines` — which scope owns the work an effect starts, and how cancellation reaches it
> - `architecture-choice` — the compass that names this skill on every client stack

## When to Use

- A new Compose screen needs state and nobody has decided who owns it
- User asks "`remember` or `rememberSaveable`", "why does my text field reset on rotation", "why does
  this list recompose on every keystroke", "do I need `derivedStateOf`", "why is my composable not
  skipping"
- A composable takes a `ViewModel` parameter, or holds a `var` that is read but never written
- A screen is visibly slow to type into, scroll or animate, and nobody has read a compiler report
- Review finds `LaunchedEffect(Unit)` in a composable that re-enters the tree, or a `remember`
  holding something the user expects back after rotation

Not for choosing the `UiState` type or deciding where a snackbar goes — that is `arch-mvvm`. Not for
the flow operators feeding the screen — `reactive-flow`. Not for what a route argument may hold —
`nav-compose`.

`references/detailed-guide.md` lies beside this file; its `## Contents` names the sections — read only the ones the table points to.

## When To Load The Reference

| Need | Reference sections |
|---|---|
| The row type every section shares, and where Multiplatform differs | `Shared Type` |
| A composable that owns too much, and the same one hoisted | `Hoisting — Before`, `Hoisting — After` |
| A plain state holder class and its `remember` factory | `State Holder` |
| Keeping a non-`Bundle`-able type across process death | `Saver for rememberSaveable` |
| Why a composable never skips, in the compiler's own words | `Stability — The Unstable Class`, `Stability — The Compiler Report` |
| `@Immutable`, immutable collections, the stability configuration file | `Stability — The Fix` |
| What strong skipping does and does not change | `Strong Skipping` |
| One sample of each effect handler, side by side | `Side Effect Handlers` |
| `derivedStateOf` earning its keep, and the same call wasted | `derivedStateOf — Pays`, `derivedStateOf — Does Not Pay` |
| Turning on compiler metrics and reading the two report files | `Diagnosing — Compiler Metrics` |
| Seeing recomposition on screen in a debug build | `Diagnosing — recomposeHighlighter` |

## Where State Lives

Start here. Every section below refines one row of this table.

| State | Owner | Survives |
|---|---|---|
| transient UI (scroll, animation, expanded) | `remember` in the composable | recomposition |
| UI that must survive rotation / process death (text input, selected tab) | `rememberSaveable` | configuration change, process death (Android) |
| screen state (data, loading, error) | ViewModel `StateFlow` | configuration change; process death via `SavedStateHandle` |
| cross-screen state | app-scoped holder or repository | app lifetime |

1. **`remember` survives recomposition and nothing else.** It is keyed by position in the
   composition, so it is dropped when the composable leaves the tree — a tab switch, a back stack
   pop, a configuration change. That is the correct lifetime for scroll offset and an animation
   target, and the wrong one for anything the user typed.
2. **`rememberSaveable` survives configuration change and process death** on Android, because it
   writes through the platform's saved-instance-state mechanism; a value that is not `Bundle`-able
   needs a `Saver` (see the reference). On Compose Desktop and on any Multiplatform target with no
   saved-state host behind it, the value does not survive a process restart — but under a
   `SaveableStateHolder`, which a navigation back stack or a tab host installs, it survives leaving
   the composition on every platform.
3. **Screen state belongs to the ViewModel**, not to a `rememberSaveable`. Saved instance state is a
   small, synchronously-written transaction; a list of orders in it is a `TransactionTooLargeException`
   waiting for a slow device. Restore it from `SavedStateHandle` plus a reload (`arch-mvvm`).
4. **Cross-screen state is app-scoped or it is a repository** — session, feature flags, a cart. A
   ViewModel scoped to a navigation graph is the widest a *screen* owner ever gets (`nav-compose`).
5. **Take the lowest row that works.** Each row down costs a lifetime that outlives the thing it
   describes, and a stale value nobody expected is harder to find than a lost one.

## Hoisting Rule

**State goes up; events come down.** A composable that reads state it does not own takes it as a
parameter, and reports what happened as a lambda:

```kotlin
// stateless: previewable, testable, reusable — the caller decides what `query` means
@Composable
fun SearchField(
    query: String,
    onQueryChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) { /* … */ }
```

1. **Hoist to the lowest common owner** — the nearest composable that must *read* the state or *react*
   to it. Higher than that and every change recomposes a subtree that did not care; lower and the
   siblings that need it cannot see it.
2. **A composable that owns state it does not itself need is a reuse blocker.** The second caller
   always wants that state controlled from outside, and the refactor is never local.
3. **State down as a value, events up as lambdas.** Never pass a `MutableState` down so the child can
   write it: two writers, no single place to log or intercept, and the child now dictates the type.
4. **Name the callback after what happened, not what to do** — `onQueryChange`, not `updateSearch`.
   The caller decides what the change means; that decision is exactly what hoisting bought.
5. **The last stateful wrapper is legal and useful.** Ship a stateless `Foo(value, onValueChange)`
   plus a thin `Foo(initial)` that holds the `remember` for callers with no opinion.
6. **Stop hoisting at the screen boundary.** State the ViewModel already owns must not be mirrored in
   a `remember` above it — there is now a second source of truth and an arrival order between them.

## State Holders

Two owners, and the choice is about *what kind of logic*, not about size.

| Holder | Created with | Owns | Lifetime |
|---|---|---|---|
| plain class | `remember { FooState() }`, or a `rememberFooState()` factory | UI logic: scroll, focus, expansion, whether the FAB is shown | the composition |
| ViewModel | `viewModel()` / `hiltViewModel()` / `koinViewModel()` | business state: loaded data, in-flight requests, validation | the back stack entry |

1. **UI logic is a plain class, not a ViewModel.** It takes the Compose objects it drives
   (`LazyListState`, `CoroutineScope`, a `Density`) in its constructor and has no reason to survive
   the composition. Making it a ViewModel gives it a lifetime that outlives the layout it describes.
2. **Business state is a ViewModel, not a state holder.** A `remember`ed class holding a repository
   loses its data on every rotation and reloads on every tab switch.
3. **Never both for the same thing.** A `remember { }` holder that mirrors a ViewModel field is two
   sources of truth for one value; the bug it produces is order-dependent and reproduces on one
   device out of ten.
4. **Follow the `rememberFooState()` convention** — a `@Composable` factory that takes the pieces to
   remember as keys and returns `remember(keys) { FooState(...) }`. Callers get one call; the keys
   are visible in one place.
5. **A holder marked `@Stable` must honour it** — the same instance for the same logical state, and
   every changing property backed by `mutableStateOf`. Lying here makes skipping silently wrong.

## Stability

Skipping is the whole performance story: a composable whose parameters are all *stable* and all
`equals`-unchanged is skipped, and its subtree with it.

1. **A type is stable if all its public properties are `val` of stable types**, or if it is annotated
   `@Immutable` (never changes after construction) or `@Stable` (may change, and notifies Compose when
   it does). Primitives, `String`, function types and `State` are stable.
2. **`List`, `Map` and `Set` from the stdlib are unstable** to the compiler: the declared type carries
   no promise that the instance is not a `MutableList` under the interface. Use
   `kotlinx.collections.immutable`'s `ImmutableList` / `PersistentList`, or list the offending types in
   a stability configuration file.
3. **A class from another module is unstable** unless that module also applies the Compose compiler,
   or a stability configuration file names it. This is why a `data class` from a pure-Kotlin domain
   module makes an otherwise clean screen recompose.
4. **Strong skipping is on by default** since the Compose compiler shipped with Kotlin 2.0.20. It lets
   a composable with unstable parameters skip anyway, comparing those parameters by instance
   (`===`) rather than by `equals`, and it memoises lambdas that capture unstable values.
5. **Strong skipping does not make an unstable type stable.** A new instance that is `equals`-equal to
   the old one still fails the `===` test, so a screen that rebuilds its list on every emission
   recomposes exactly as before — annotating and using immutable collections is what makes that
   comparison succeed.
6. **`@Immutable` is a promise the compiler cannot check.** Annotating a class whose contents change
   makes Compose skip a recomposition that was needed, and the screen shows stale data.
7. **`var` in a class is not observable state.** A `@Stable` class exposes changing values through
   `mutableStateOf` (or a `StateFlow` the caller collects); a plain `var` changes without waking the
   composition.

## Side Effects

Every one of these exists because a composable body must stay side-effect free and may run any number
of times. One rule each:

| Handler | Rule |
|---|---|
| `LaunchedEffect(key)` | run a coroutine tied to the composition; it is cancelled and re-launched when a key changes, and `Unit` as the key means once per entry into the composition |
| `rememberCoroutineScope()` | the scope for work started from a callback rather than from composition; cancelled when the caller leaves the composition |
| `DisposableEffect(key)` | anything with a register/unregister pair — a listener, an observer, a system callback — released in `onDispose` |
| `SideEffect { }` | publish committed Compose state to a non-Compose object; it runs after **every** successful composition, so keep it to an assignment |
| `produceState(initial, key)` | turn a non-Compose source (a callback API, a `Flow`, a `suspend` call) into a `State` the composable can read |
| `snapshotFlow { }` | the other direction: turn a Compose state read into a `Flow`, which emits only when the read value actually changes |

1. **Keys are the contract, not decoration.** A `LaunchedEffect(Unit)` that should restart per item is
   the most common effect bug: the first item's work runs forever and the second item never loads.
2. **Never launch from the composable body.** `viewModelScope.launch { }` written directly in a
   composable runs once per composition — an unbounded number of times.
3. **A `LaunchedEffect` cannot outlive the composition.** Work that must finish after the user
   navigates away belongs to a wider scope (`concurrency-coroutines`), not to a longer key.
4. **`rememberCoroutineScope()` is for callbacks only.** In a composable body it is the wrong tool —
   that is what `LaunchedEffect` is.
5. **One-shot effects arriving *from* the ViewModel** — navigation, a snackbar — are a different
   problem with a different answer; see `arch-mvvm`.

## Derived State

`derivedStateOf` creates a state whose readers recompose only when the *derived* value changes, not
when its inputs do.

1. **Use it when the input changes much more often than the output.** The canonical case is
   `listState.firstVisibleItemIndex > 0` driving a scroll-to-top button: the index changes on every
   frame of a fling, the boolean twice a screen.
2. **Do not use it when the output changes as often as the input.** A filtered list derived from a
   query string changes on every keystroke, so the wrapper adds a snapshot observer and an allocation
   and prevents nothing.
3. **The derivation must be cheaper than the recomposition it prevents.** It runs on read; a heavy
   sort inside it moves the cost rather than removing it. `remember(key) { }` is the right tool for an
   expensive value keyed by its input.
4. **Only Compose state counts as an input.** A plain variable read inside the block is not observed,
   so the derived value silently never updates.
5. **Never wrap a ViewModel-owned computation in it.** Derive in the ViewModel, where it is testable
   without a composition.

## Diagnosing Recomposition

Measure before annotating. The compiler will tell you which composables it could not skip and why.

1. **Turn on the Compose compiler reports** in the module's `build.gradle.kts` (Kotlin 2.0+ Compose
   compiler Gradle plugin):

```kotlin
composeCompiler {
    reportsDestination = layout.buildDirectory.dir("compose_reports")
    metricsDestination = layout.buildDirectory.dir("compose_metrics")
}
```

2. **Read the two report files.** `<module>_<variant>-classes.txt` marks every class `stable`,
   `unstable` or `runtime`, naming the property responsible; `<module>_<variant>-composables.txt`
   marks each function `skippable`, `restartable` and lists each parameter as `stable` or `unstable`.
   A hot composable that is not `skippable` is where the work goes.
3. **Confirm on device with Layout Inspector.** Android Studio shows a recomposition count and a skip
   count per composable while the app runs — the count that keeps climbing while nothing changes is
   the bug.
4. **`Modifier.recomposeHighlighter()` for a visual answer.** It draws a border around any composable
   that just recomposed. It is a snippet from the official Compose samples, not a library
   dependency — copy it into a debug source set, and never ship it.
5. **Diagnose a release-shaped build.** A debug build without R8, with the debugger attached and with
   the highlighter drawing, is not the timing anyone ships.
6. **Fix the parameter, not the symptom.** Making a screen `@Immutable` to silence a report, when the
   real input is a stdlib `List` rebuilt per emission, moves the problem behind an annotation that
   now also lies.

## Common Mistakes

1. **`var expanded = false` in a composable body** — a plain local, reset on every recomposition, so
   the row never opens. It has to be `var expanded by remember { mutableStateOf(false) }`; a `var`
   that is read but never survives is the signature.
2. **`remember { mutableStateOf(text) }` for a text field** — the typed value is gone after rotation,
   and the bug report says "the form clears itself when I turn the phone". Anything the user produced
   is `rememberSaveable`, or it belongs to the ViewModel.
3. **`rememberSaveable` holding a screen's worth of data** — a loaded list written into saved instance
   state on every background transition, until a device with a slower main thread throws
   `TransactionTooLargeException`. Save the key, reload the data.
4. **Passing `MutableState` down to a child** so it can write the parent's state. Two writers on one
   value, no seam to log or validate at, and the child is now typed against Compose's state API rather
   than against its own inputs. Pass the value and a lambda.
5. **A composable that takes a `ViewModel`** — it cannot be previewed, cannot be screenshot-tested,
   and cannot be reused with a different source. Only the route-level composable touches the
   ViewModel (`arch-mvvm`).
6. **`LaunchedEffect(Unit)` where the key should be the identity of the thing loaded** — the detail
   screen loads the first item and then shows it for every later one, because the effect never
   restarted. Key the effect on what it depends on.
7. **A repository call, a `try/catch` or a `launch` in the composable body** — the body runs an
   unpredictable number of times per frame, so the call does too. Effects go in an effect handler;
   business work goes in the ViewModel.
8. **`@Immutable` sprinkled to fix a report** without checking whether the class can change. Compose
   then skips a recomposition that was necessary, and the screen shows a value that is no longer
   true — a much worse bug than the one being fixed.
9. **Assuming strong skipping made stability moot.** It compares unstable parameters by instance, so a
   state object rebuilt on every emission still fails, and a stdlib `List` recreated per `map` still
   defeats the skip. Immutable collections and `@Immutable` still decide the outcome.
10. **`derivedStateOf` on everything that looks derived** — added by reflex to values that change with
    every keystroke, it costs an observer and an allocation and skips nothing. It pays only where the
    output changes far less often than the input.
11. **Optimizing from a hunch.** Annotations added with no compiler report and no Layout Inspector
    reading are a diff nobody can evaluate, and they usually miss the one unstable parameter that was
    actually costing the frames.
