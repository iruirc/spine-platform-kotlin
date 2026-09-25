---
name: nav-multiplatform
description: "Use when choosing and wiring navigation in a Kotlin Multiplatform UI — Compose Multiplatform navigation-compose or Navigation 3, Decompose or Voyager. Covers the comparison, back handling per platform, state preservation across Android, iOS and desktop, and keeping navigation out of commonMain business logic."
---

# Navigation in Kotlin Multiplatform

Four libraries answer the same question — who owns the back stack when one UI serves Android, iOS
and desktop — and they answer it differently enough that the choice is hard to reverse. This file
makes that choice, states what back and state preservation actually mean on each target, and fixes
the one boundary that keeps the choice reversible. An Android-only or Desktop-only graph is
`nav-compose`, whose type-safe route rules apply here unchanged.

> **Related skills:**
> - `nav-compose` — the single-target graph, and the Navigation Compose API the JetBrains port mirrors
> - `nav-deeplinks` — the URL half, and the typed Route it hands to whichever library below you picked
> - `arch-mvvm` — the effect a shared ViewModel emits where it would otherwise navigate
> - `compose-state` — `rememberSaveable` and `SaveableStateHolder`, and what each of them survives
> - `pkg-kmp-source-sets` — where the shared `Route` sits, and which source set holds each host's graph file
> - `di-koin` — `koinViewModel()` for the shared ViewModels, and the back-stack entry it scopes them to
> - `architecture-choice` — the compass that names this skill as soon as `target` resolves to KMP

## When to Use

- The project guidance file's `## Stack` names KMP with a shared Compose UI, and a second screen
  just appeared
- A shared module has to move the user somewhere and nobody has said who owns the back stack
- User asks "Decompose or Voyager", "how does back work on iOS", "does my state survive a relaunch
  on iOS", "can I use Navigation Compose in `commonMain`"
- Review finds a navigation library type imported by a ViewModel or a use case in `commonMain`
- The iOS half of the app is drawn by the platform's own UI toolkit and the shared stack has to cope

Not for a graph that only ever runs on Android or Desktop — that is `nav-compose`, whose rules about
typed routes and the ViewModel boundary hold for every library named here. Not for turning a URL
into a destination: `nav-deeplinks` owns that end.

## The Options

| | `org.jetbrains.androidx.navigation:navigation-compose` | `org.jetbrains.androidx.navigation3:navigation3-ui` | Decompose | Voyager |
|---|---|---|---|---|
| Model | `NavController` + `NavHost`, the same API as Android's | a back stack the app holds, drawn by `NavDisplay` — Android's Navigation 3 | a tree of components, each with a `ComponentContext`; `childStack` driven by `StackNavigation` | screens as objects, held in a `Navigator`'s list |
| Typed destinations | `@Serializable` routes, exactly as in `nav-compose` | `@Serializable` `NavKey`s, as in `nav-compose` | a `@Serializable` sealed `Config` per stack | the `Screen` object carries its own arguments |
| Needs Compose | yes | yes | no — the component tree is plain Kotlin, a UI is attached to it | yes |
| Lifecycle & retention | Compose's, plus the multiplatform `ViewModel` | Compose's, plus a `ViewModel` scoped per entry by the ViewModel-store decorator (`nav-compose` → "Routes as Types") | its own: `Lifecycle`, `StateKeeper`, `InstanceKeeper`, `BackHandler` (Essenty) | `ScreenModel`, retained by the `Navigator` |
| Nested / parallel stacks | nested graphs, one active stack | as many lists as the app keeps | native to the model: a component owns children | one `Navigator` per nesting level |
| Maturity | stable; iOS and web support still maturing | stable, and the newest of the four | mature and steadily released | simplest to adopt; maintenance cadence is slower than the others |

1. **Take `navigation-compose` when the team already knows Navigation Compose** and every target
   renders with Compose Multiplatform. The API, the typed routes and every rule in `nav-compose`
   transfer, so a shared screen and an Android-only screen are written the same way. Pin the version
   and read the release notes: this is where the port is still moving.
2. **Take Navigation 3 when the back stack is application state** — the signals are
   `nav-compose` → "Which Library", and they read the same with a shared UI.
3. **Take Decompose when navigation must exist without a UI.** Its stack is a tree of plain Kotlin
   components, so it is testable with no Compose runtime, it survives a screen being rendered by the
   platform's own UI toolkit instead of Compose, and nested or parallel stacks (a tab holding its own
   stack, a dialog as a component) are the model rather than a workaround. The cost is ceremony:
   every component takes a `ComponentContext`, and retention is something you declare.
4. **Take Voyager when the app is small and the stack is a list of screens.** A `Screen` object and a
   `Navigator` is all there is to learn. Weigh it with open eyes: its release cadence is slower than
   the others, so treat "the version we pinned is the version we have for a while" as part of the
   decision rather than as a surprise.
5. **One library per app.** Two of them means two back stacks, and system back reaches one of them.
   Whichever you pick, keep it inside the graph file below, so the day the pick is wrong the damage
   is one file.

**When in doubt**, and the app is Compose everywhere with an Android-shaped team, start with
`navigation-compose`. Reach for Decompose the moment a non-Compose UI host or a genuinely nested
stack is on the roadmap — retrofitting the component tree later is the expensive direction.

## Back Handling

Back is not one gesture. It is three different platform facts sharing a name:

| Target | What "back" is | What the library must map |
|---|---|---|
| Android | the system back button and the predictive-back gesture | `OnBackPressedDispatcher`, which feeds the `NavigationEventDispatcher` |
| iOS | the edge swipe and the navigation bar's back control | both, and the swipe wants a live progress preview to feel right |
| Desktop | the `Esc` key, which the window hands to its `NavigationEventDispatcher` | nothing — `NavHost` and `NavDisplay` already pop on it |

1. **One back abstraction in `commonMain`, and every screen calls it** — `NavigationBackHandler`
   from `androidx.navigationevent.compose`, which every target's dispatcher feeds. It replaces
   `BackHandler` and `PredictiveBackHandler` from `org.jetbrains.compose.ui:ui-backhandler`,
   deprecated in Compose Multiplatform 1.12; the artifact still carries it in as a dependency.

<!-- compile: kmp -->
```kotlin
// commonMain
import androidx.navigationevent.NavigationEventInfo
import androidx.navigationevent.compose.NavigationBackHandler
import androidx.navigationevent.compose.rememberNavigationEventState

@Composable
fun EditorScreen(state: EditorState, onDiscard: () -> Unit, onBack: () -> Unit) {
    NavigationBackHandler(
        state = rememberNavigationEventState(NavigationEventInfo.None),
        isBackEnabled = state.hasUnsavedChanges,
        onBackCompleted = onDiscard,
    )
    EditorScaffold(state = state, onBack = onBack)
}
```

2. **Decompose brings its own**, from Essenty. Its `PredictiveBackGestureOverlay` draws an edge-swipe
   preview on the targets whose OS has no such gesture; it exists only outside Android and is
   `@ExperimentalDecomposeApi`. If the app is on Decompose, use its handler and do not mix in
   `NavigationBackHandler`.
3. **On desktop `Esc` is the only back, and nobody finds it.** Every back path also needs a drawn
   control, and that control calls the same `onBack` lambda the handler does. Never bind `Esc` to
   `onBack` yourself: the key already reaches the dispatcher, and a handler that does not consume it
   pops the stack twice.
4. **Intercept back only for modal UI** — an unsaved-changes dialog, a bottom sheet, a step inside
   one destination — and keep the interception conditional, exactly as `nav-compose` states it for
   the single-target case. An always-on handler cancels the predictive-back preview on Android.
5. **Never `expect`/`actual` back handling per screen.** The abstraction is one function; screens
   call it and know nothing about the target. A per-screen `expect` multiplies the same three lines
   by the number of screens and leaves an empty desktop `actual` in each (`pkg-kmp-source-sets`).

## State Preservation

The three targets do not lose state in the same way, and only one of them hands anything back:

| Event | Android | iOS | Desktop |
|---|---|---|---|
| Rotation / window resize | recreates the activity; the composition goes, retained objects stay | nothing is recreated | nothing is recreated |
| The OS reclaims a backgrounded app | the process dies and is later restored with its saved state handed back | the process dies; the next launch is a cold launch | the process dies; the next launch is a cold launch |

**iOS has no process-death restoration the way Android does.** When the system reclaims a
backgrounded app it is simply relaunched, at the start destination, with nothing returned to it —
not the back stack the library filed, not a saved bundle, because there is no bundle. Anything the
user must find where they left it goes into real storage (`persistence-architecture`) and is read
back on launch, by the app, deliberately.

1. **`navigation-compose` preserves through `rememberSaveable`**, the back stack included. On
   Android that reaches across process death; everywhere else it lives exactly as long as the
   process does. The rules for what may go in one, and for `SaveableStateHolder`, are
   `compose-state`'s.
2. **Decompose splits retention in two, and you declare both.** `StateKeeper` holds serializable
   state and is written into the platform's saved state, so on Android it survives process death;
   `InstanceKeeper` holds live objects and survives configuration change but never process death.

```kotlin
class OrderDetailComponent(context: ComponentContext, id: String) : ComponentContext by context {
    private val state = MutableValue(
        stateKeeper.consume(key = "state", strategy = State.serializer()) ?: State(id = id)
    )
    private val worker = instanceKeeper.getOrCreate { OrderWorker() } // : InstanceKeeper.Instance

    init { stateKeeper.register(key = "state", strategy = State.serializer()) { state.value } }
}
```

3. **Voyager retains a `ScreenModel` for as long as its `Screen` is in the stack**, configuration
   change included, and saves nothing for you. What must come back after a restore is a
   `rememberSaveable` you wrote.
4. **Design for the strictest target, which is Android's process death.** Test it there — kill the
   process from the tooling, or turn on "Don't keep activities" — and the other two targets are
   right by construction, because they ask for strictly less.
5. **Keep whatever is saved small.** A route holds an id, never a loaded object: the same rule as
   `nav-compose`'s arguments, except that on Android the saved-state size limit turns a violation
   into a crash rather than a smell.

## Where Navigation Lives

The shared code names destinations and asks to move. It never learns which library moves it.

<!-- compile: kmp -->
```kotlin
// commonMain — the vocabulary every target shares
@Serializable
sealed interface Route {
    @Serializable data object Home : Route
    @Serializable data class OrderDetail(val id: String) : Route
    @Serializable data class Search(val query: String? = null) : Route
}

interface Navigator {
    fun navigate(route: Route)
    fun back()
}
```

<!-- compile: kmp -->
```kotlin
// the graph file — the one file that imports the library; the controller is born and dies here
class NavHostNavigator(private val controller: NavHostController) : Navigator {
    override fun navigate(route: Route) { controller.navigate(route) }
    override fun back() { controller.popBackStack() }
}

@Composable
fun AppNavHost() {
    val navController = rememberNavController()
    val navigator = remember(navController) { NavHostNavigator(navController) }
    NavHost(navController, startDestination = Route.Home) {
        composable<Route.Home> { HomeRoute(onOpenOrder = { navigator.navigate(Route.OrderDetail(it)) }) }
        composable<Route.OrderDetail> { entry ->
            OrderDetailRoute(id = entry.toRoute<Route.OrderDetail>().id, onBack = navigator::back)
        }
    }
}
```

1. **A ViewModel or use case in `commonMain` depends on no navigation type** — not the library's,
   not `Navigator`. It emits an effect and the Route turns it into one of the lambdas above:
   `nav-compose` → "The Boundary", which holds for every library in this file.
2. **`Route` is the shared vocabulary**, and it is the type `nav-deeplinks` produces from a URL. One
   sealed hierarchy, one place a new screen is added, one thing a test constructs.
3. **The graph file is the swap point.** It alone imports the library, owns the controller and
   hands each Route its lambdas, so replacing the library rewrites this file and no screen. Under
   Decompose the parent component is this file: a child takes `onOpenOrder` in its constructor and
   the parent pushes. A host that draws its own screens gets its own graph file;
   `pkg-kmp-source-sets` decides which source set holds each.
4. **`Navigator` lives exactly as long as the controller it wraps** — `remember`ed beside it and
   handed to what moves the user from outside a screen: the deep-link replay effect, a sign-out at
   the root. It is never a DI binding, for the reason `nav-compose` → "The Boundary" gives.
5. **Voyager also has a type called `Navigator`.** Import-alias the library's one inside its
   implementation file; do not rename the interface. Its name is the app's vocabulary and it is the
   same word on every target.
6. **Keep the interface at two functions.** `navigate` and `back` carry almost everything; add a
   third for a real flow (reset the stack after sign-out) when one appears. A method per screen has
   turned the interface into the graph, and the graph now lives in `commonMain` again.

## Common Mistakes

1. **A library type in `commonMain` business code** — a ViewModel holding a `NavHostController`, a
   `ComponentContext`, or Voyager's `Navigator`. The shared module now compiles only where that
   library does, and swapping it means editing every ViewModel: exactly the cost the graph file above
   exists to buy off.
2. **Two navigation libraries in one app**, usually because a feature was ported with its own. They
   share no stack, so back reaches one of them and the other's screens strand the user.
3. **Assuming Android's process-death restore exists on iOS** — a "resume where you left off" flow
   verified only on Android. On iOS the reclaimed app relaunches cold at the start destination; if
   the user must find their place, that place is storage, not the navigation library.
4. **`expect`/`actual` back handling per screen** — the same three lines copied per screen per
   target, with an empty desktop `actual` in each. One abstraction, called by every screen.
5. **`rememberSaveable` holding navigation state under Decompose** — the stack belongs to the
   component tree, which already filed it through `StateKeeper`. After a restore the two disagree,
   and the UI shows a screen the tree does not have.
6. **Voyager chosen for its simplicity, then a host that draws its own screens arrives.** Its stack
   lives inside Compose, so a screen the OS renders itself has no entry in it. That case is the
   Decompose row of the table, and meeting it late costs a rewrite rather than a decision.
7. **A `ScreenModel` or ViewModel hoisted to app scope to "share state between screens"** — it now
   outlives the screen's removal from the stack, so the next visit opens on the last visit's state.
