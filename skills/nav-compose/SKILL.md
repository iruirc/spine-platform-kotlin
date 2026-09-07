---
name: nav-compose
description: "Use when wiring navigation in an Android or Compose Desktop app with Navigation Compose or Navigation 3. Covers type-safe routes with @Serializable, nested graphs, arguments and results, bottom bar and tab state, back handling, the ViewModel/navigation boundary, and where deep links plug in."
---

# Navigation in Compose

The graph a screen is registered in: which library owns the back stack, what a destination is named
by, how an argument and a result cross between two screens, and where navigation stops being the
ViewModel's business. What a screen holds while it is on screen is `arch-mvvm` and `compose-state`;
the same graph on a Multiplatform target, where the library list changes, is `nav-multiplatform`.

> **Related skills:**
> - `nav-multiplatform` — the same decision when the UI is shared with iOS, and why neither library below leads that list
> - `nav-deeplinks` — the URL half: intent filters, verification, and the parser that hands this graph a typed Route
> - `arch-mvvm` — the effect channel behind the navigation lambdas the Route composable wires here
> - `arch-mvi` — the same boundary when the screen's state machine is a reducer instead of an `update {}`
> - `compose-state` — `rememberSaveable`, `SaveableStateHolder`, and what a back-stack entry keeps alive
> - `di-hilt` — `@HiltViewModel`, and what `hiltViewModel(parentEntry)` is actually scoping to
> - `di-koin` — `koinViewModel(viewModelStoreOwner = parentEntry)` and the same scoping without Hilt
> - `architecture-choice` — the compass that names this skill on every Android and Compose Desktop stack

## When to Use

- The project guidance file's `## Stack` names Android or Desktop with Compose, and a second screen
  just appeared
- User asks "how do I pass an object to the next screen", "how do I get a result back", "why does my
  bottom bar reset the scroll position", "how do I navigate from a ViewModel", "Navigation 3 or not"
- Review finds a route string with a `${}` in it, or a `NavController` in a ViewModel's constructor

Not for what a screen holds while it is on screen (`compose-state`), nor for the shape of its
`UiState` and effects (`arch-mvvm`). Not for turning a URL into a destination: `nav-deeplinks` owns
that end and hands the typed Route here.

## Which Library

Two libraries from the same team with incompatible models: Navigation Compose 2.8+ owns the back
stack for you, and Navigation 3 hands it back.

| Question | Navigation Compose 2.8+ | Navigation 3 (`androidx.navigation3`) |
|---|---|---|
| Who owns the back stack | the library, inside `NavController` | you — a `SnapshotStateList<NavKey>` the app holds |
| A destination is | a `@Serializable` type registered by `composable<T>` | a `NavKey` the `entryProvider` maps to content |
| Two panes on one screen | one destination hosting both, hand-rolled | a `SceneStrategy`; `ListDetailSceneStrategy` ships |
| Surviving process death | automatic for the whole graph | `rememberNavBackStack(...)`, keys `@Serializable` |
| Maturity | stable, the Android default | alpha — the API still moves between releases |

**Take Navigation 3 when the back stack is application state.** One signal is enough: the app must
compute its own stack (an adaptive layout collapsing two destinations into one pane, a wizard whose
steps depend on the answers, a stack restored from the server), or multi-pane is a requirement and
`ListDetailSceneStrategy` is the feature you are about to hand-roll. Accept the alpha churn.

**Take Navigation Compose when the project already runs it**, and in a new project matching no
signal above. It is stable, every Android answer in circulation assumes it, and the type-safe API in
2.8 removed the one thing that used to be wrong with it. On Compose Desktop the coordinate is
JetBrains' `org.jetbrains.androidx.navigation:navigation-compose` — the same type-safe API, so every
sample below reads the same on both targets.

**Never both in one app.** They share no back stack, so a destination in one is invisible to the
other and system back reaches exactly one. The rest of this file is written against Navigation
Compose, naming the Navigation 3 counterpart wherever the shapes differ.

## Routes as Types

A destination is a `@Serializable` type. No route in this file is a string.

```kotlin
// in the module every feature depends on: a sealed family is extended only where it is declared
@Serializable
sealed interface Route {
    @Serializable data object Home : Route
    @Serializable data class OrderDetail(val id: String) : Route
    @Serializable data class Search(val query: String? = null) : Route
    // Invoice(id) and Checkout — further members of this family, elided here
}

NavHost(navController, startDestination = Route.Home) {
    composable<Route.Home> {
        HomeRoute(onOpenOrder = { id -> navController.navigate(Route.OrderDetail(id)) })
    }
    composable<Route.OrderDetail> { backStackEntry ->
        val args = backStackEntry.toRoute<Route.OrderDetail>()
        OrderDetailRoute(id = args.id, onBack = { navController.popBackStack() })
    }
}
```

1. **Apply the `kotlinx-serialization` compiler plugin.** The library builds the route pattern from
   the generated serializer; without the plugin `@Serializable` produces nothing and the destination
   fails to register at runtime, not at compile time.
2. **Never a string route.** `"detail/${id}"` is a typo waiting to become a crash, an argument with
   no type, and an id that breaks the pattern the first time it contains a slash.
3. **An argument carries identity, not payload.** `OrderDetail(val id: String)`, and the ViewModel
   loads the order. A route is saved state and can be spelled as a URL, so what rides in it is
   size-capped, stale by the time it is read, and public.
4. **A field with a default becomes an optional query argument**, every other field a path segment.
   Nullability alone does not do it: `Search(val query: String? = null)` is optional for the `=`.
5. **A custom type in a route needs its own `NavType`**, passed per destination through
   `composable<T>(typeMap = ...)` — and wanting one is usually rule 3 being violated.
6. **The ViewModel reads its own arguments** with `savedStateHandle.toRoute<Route.OrderDetail>()` — not a
   string key, and not a `NavController` it should not have.

The same two screens under Navigation 3, where keys are `NavKey` and the stack is yours:

```kotlin
// the same family, with `NavKey` on the interface: `sealed interface Route : NavKey`
val backStack = rememberNavBackStack(Route.Home)
NavDisplay(
    backStack = backStack,
    onBack = { backStack.removeLastOrNull() },
    entryProvider = entryProvider {
        entry<Route.Home> { HomeRoute(onOpenOrder = { backStack.add(Route.OrderDetail(it)) }) }
        entry<Route.OrderDetail> { key -> OrderDetailRoute(id = key.id, onBack = { backStack.removeLastOrNull() }) }
    },
)
```

## Graph Layout

**One graph per feature, nested inside the root graph.** The feature module exposes an extension on
`NavGraphBuilder`; the app module installs it and never learns which screens are inside.

```kotlin
@Serializable data object OrdersGraph

// in the orders feature module
fun NavGraphBuilder.ordersGraph(navController: NavHostController, onOpenInvoice: (String) -> Unit) {
    navigation<OrdersGraph>(startDestination = Route.Home) {
        composable<Route.Home> { HomeRoute(onOpenOrder = { navController.navigate(Route.OrderDetail(it)) }) }
        composable<Route.OrderDetail> { OrderDetailRoute(onOpenInvoice = onOpenInvoice) }
    }
}

// in the app module
NavHost(navController, startDestination = OrdersGraph) {
    ordersGraph(navController, onOpenInvoice = { navController.navigate(Route.Invoice(it)) })
}
```

1. **Nesting buys three things** and is not worth it otherwise: a `ViewModelStoreOwner` per feature,
   one name the rest of the app navigates to, and one place to hang the feature's deep links.
2. **The graph's start destination is the screen the user must see first — never a splash.** A
   splash is a state of the first screen or the system splash screen API, not a destination, and the
   Common Mistakes entry below is what putting one here costs.
3. **Two levels cover almost everything**: root → feature. A third level is for a genuinely nested
   flow — a wizard, a checkout — where the inner stack is popped as a unit.
4. **A feature graph does not name another feature's destinations.** It takes a lambda, as above.
   Otherwise the module graph and the navigation graph are the same graph, and neither can change.
5. **Navigation 3 has no graph object.** A feature exposes an `EntryProviderBuilder` extension, the
   stack stays flat, and grouping is by key type and scene strategy — rule 4 survives the change.

## Passing Results Back

Two mechanisms, and the split between them is how long the value has to live.

**A one-off pick — the previous entry's `SavedStateHandle`.** The picker writes into the entry it
will return to, then pops:

```kotlin
private const val PickedCurrency = "picked_currency"

// in the picker's Route, on the way out
navController.previousBackStackEntry?.savedStateHandle?.set(PickedCurrency, code)
navController.popBackStack()

// in the Route of the screen that asked — `composable<Route.Checkout> { entry -> CheckoutRoute(entry, …) }`
@Composable
fun CheckoutRoute(
    entry: NavBackStackEntry,
    viewModel: CheckoutViewModel = hiltViewModel(), // Android; koinViewModel() on Desktop
) {
    val picked by entry.savedStateHandle.getStateFlow<String?>(PickedCurrency, null)
        .collectAsStateWithLifecycle()
    LaunchedEffect(picked) {
        val code = picked ?: return@LaunchedEffect
        viewModel.onCurrencyPicked(code)
        entry.savedStateHandle.remove<String>(PickedCurrency)
    }
}
```

**A multi-step flow — a ViewModel scoped to the parent graph.** Three screens editing one draft
share one ViewModel whose store owner is the graph entry, so it dies when the flow is popped:

```kotlin
composable<Route.OrderDetail> { entry ->
    val parentEntry = remember(entry) { navController.getBackStackEntry<OrdersGraph>() }
    val draft: OrderDraftViewModel = hiltViewModel(parentEntry)
    // with Koin: koinViewModel<OrderDraftViewModel>(viewModelStoreOwner = parentEntry)
    OrderDetailRoute(draft = draft)
}
```

1. **Remove the value after reading it.** It is saved state: leave it and the effect fires again
   every time the caller is returned to, including after process death.
2. **The key is a constant declared once**, not the same literal typed in two files — a mismatch is
   silent, and the reader simply never sees a result.
3. **Never a singleton mailbox.** An app-scoped ViewModel or a top-level `MutableStateFlow` used to
   pass a result outlives both screens, so the second visit reads the first visit's answer. And a
   result obeys the argument rule: an id or a small value, never a loaded object.
4. **Navigation 3 needs neither**: the back stack is app state, so a value two entries share is a
   state holder hoisted above `NavDisplay`.

## Tabs and Bottom Bar

Each tab is a nested graph with its own back stack. Three options on the `navigate` call are what
keep those stacks apart:

```kotlin
fun NavHostController.switchTab(tabGraph: Any) = navigate(tabGraph) {
    popUpTo(graph.findStartDestination().id) { saveState = true }
    launchSingleTop = true
    restoreState = true
}

@Composable
fun AppBottomBar(navController: NavHostController, tabs: List<Tab>) {
    val entry by navController.currentBackStackEntryAsState()
    NavigationBar {
        tabs.forEach { tab ->
            val selected = entry?.destination?.hierarchy?.any { it.hasRoute(tab.graph::class) } == true
            NavigationBarItem(selected = selected, icon = { Icon(tab.icon, null) },
                onClick = { navController.switchTab(tab.graph) })
        }
    }
}
```

1. **`popUpTo(graph.findStartDestination().id)` with `saveState = true`** pops to the root before
   pushing, so the stack does not grow one entry per tap, and files the departing tab's entries and
   their `rememberSaveable` state under that tab.
2. **`launchSingleTop = true`** makes a second tap on the current tab a no-op instead of a duplicate
   entry.
3. **`restoreState = true`** brings the arriving tab's filed stack back. Drop it and the tab reopens
   at its start destination with the scroll position gone — reported as "the app forgets where I was".
4. **Selection is read from the destination hierarchy, not a `var selectedTab`.** The current
   destination is usually nested inside the tab's graph, so a `==` against the tab's own route
   deselects the whole bar the moment the user opens anything.
5. **Whether the bar shows is decided in the scaffold from the current entry**, not by a flag a
   screen raises on the way in — such a flag outlives the screen that set it.
6. **Navigation 3 spells multiple back stacks literally**: keep a map from tab to
   `SnapshotStateList<NavKey>`, hand `NavDisplay` the active one, and saving is the map's problem.

## Back

1. **System back is the default and needs no code.** `NavHost` registers the handler; the back
   button and the predictive-back gesture pop the stack. Every line below is an exception to this.
2. **`BackHandler` is for modal UI only** — a bottom sheet, an unsaved-changes dialog, a step inside
   a single destination — and it is enabled conditionally so it is transparent when it has nothing
   to say:

```kotlin
BackHandler(enabled = state.hasUnsavedChanges) { // Android; Desktop draws its own back affordance
    showDiscardDialog = true
}
```

3. **An always-enabled `BackHandler` opts the screen out of the predictive-back preview**: the
   system cannot animate towards a destination the app has taken over. When the gesture's progress
   is genuinely wanted — a sheet that follows the drag — use `PredictiveBackHandler`.
4. **`popBackStack()` returns a `Boolean`, and on the root destination it returns `false`.** Check
   it: on Android finish the activity, on Desktop close the window. Ignore it and the user presses
   back on a screen that does not move.
5. **Compose Desktop has no system back at all.** The app draws the affordance — a toolbar arrow, an
   `Esc` binding, a mouse side button — and `popBackStack()` sits behind each.

## The Boundary

Three composables per destination, and each one knows strictly less than the one above it:

```kotlin
composable<Route.OrderDetail> {
    OrderDetailRoute(
        onBack = { navController.popBackStack() },
        onOpenInvoice = { id -> navController.navigate(Route.Invoice(id)) },
    )
}

@Composable
fun OrderDetailRoute(
    onBack: () -> Unit,
    onOpenInvoice: (String) -> Unit,
    viewModel: OrderDetailViewModel = hiltViewModel(), // Android; koinViewModel() on Desktop
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    OrderDetailScreen(state = state, onEvent = viewModel::onEvent, onBack = onBack)
}
```

1. **The ViewModel never sees a `NavController`** — not as a constructor parameter, not through DI,
   not as a field set after construction.
2. **The Screen receives lambdas** — `onNavigateToDetail: (String) -> Unit`, `onBack: () -> Unit` —
   and takes no `NavController` and no ViewModel, which is what makes it previewable and testable
   with no graph present.
3. **The Route is the only composable holding both.** It resolves the ViewModel, collects the state,
   and turns a ViewModel effect into a lambda call. The effect channel itself is `arch-mvvm`'s; this
   file only fixes the place it lands.
4. **Lambdas are named for the intent, not the mechanism** — `onOpenInvoice`, never `navigate`, so
   the same Screen serves a tablet pane that opens the invoice beside it rather than above it.

## Deep Links

A destination declares the URL it answers to; `nav-deeplinks` owns everything upstream of that.

```kotlin
composable<Route.OrderDetail>(
    deepLinks = listOf(navDeepLink<Route.OrderDetail>(basePath = "https://example.com/orders")),
) { /* … */ }
```

## Testing

```kotlin
@Test
fun openingAnOrderNavigatesToDetail() {
    lateinit var navController: TestNavHostController
    composeRule.setContent { // Android instrumented; on Desktop test through the Navigator interface
        navController = TestNavHostController(LocalContext.current)
        navController.navigatorProvider.addNavigator(ComposeNavigator())
        AppNavHost(navController = navController)
    }
    composeRule.onNodeWithText("Order 42").performClick()

    assertTrue(navController.currentBackStackEntry?.destination?.hasRoute<Route.OrderDetail>() == true)
}
```

1. **Register every navigator the graph uses** — `ComposeNavigator()` always, `DialogNavigator()`
   too when the graph has dialogs. A missing one fails while the graph is built, naming the
   destination rather than the navigator.
2. **Assert with `hasRoute<T>()`, read arguments with `toRoute<T>()`.** A test comparing a route
   string asserts on the pattern the library generated, which is not the contract.
3. **Most navigation behaviour needs no graph at all.** The Screen takes lambdas, so its own test
   asserts the right lambda fired with the right id, and the graph test above is written once per
   feature. Navigation 3 needs no test controller either: the back stack is a list the test built.

## Common Mistakes

1. **A string route with an argument interpolated into it** — `"order/${id}"` registered on one side
   and parsed on the other. A typo is a runtime crash on a screen nobody opens in review, the id has
   no type, and the first value containing a slash or a space silently matches nothing.
2. **A `NavController` in the ViewModel** — injected, passed in, or set from the composable. It
   leaks the graph into the one layer that must not know a graph exists, and the ViewModel is then
   untestable without one and the screen unreachable from a second graph.
3. **A whole object as a route argument** — the loaded `Order` serialized into the destination. The
   route is saved state and can be written as a URL, so the payload is size-capped, already stale
   when the screen reads it, and visible to anyone who can see the link. Pass the id.
4. **A bare `navigate()` on a tab tap** — no `popUpTo`, no `saveState`, no `restoreState`. The stack
   grows one entry per tap, back walks the user through their tab history instead of leaving, and
   every return to a tab starts it over at the top of the list.
5. **An always-enabled `BackHandler`** — declared without the `enabled` argument because the screen
   sometimes needs it. It swallows back for the whole screen, cancels the predictive-back preview,
   and reaches the user as "the back button does nothing here".
6. **A splash as the graph's start destination.** `popUpTo(findStartDestination())` now returns to
   it, back from the first real screen shows it again, and a restore after process death lands the
   user on a spinner. A splash is a state of the first screen, or the system splash screen API.
7. **An argument read by string key** — `savedStateHandle["id"]` beside a type-safe route. Nothing
   checks the key, so a rename makes it `null` and the screen renders an empty state instead of
   failing. `savedStateHandle.toRoute<Route.OrderDetail>()` is the same line, typed.
