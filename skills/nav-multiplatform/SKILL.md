---
name: nav-multiplatform
description: "Use when choosing and wiring navigation in a Kotlin Multiplatform UI — Compose Multiplatform navigation-compose, Decompose or Voyager. Covers the comparison, back handling per platform, state preservation across Android, iOS and desktop, and keeping navigation out of commonMain business logic."
---

# Navigation in Kotlin Multiplatform

Three libraries answer the same question — who owns the back stack when one UI serves Android, iOS
and desktop — and they answer it differently enough that the choice is hard to reverse. This file
makes that choice, states what back and state preservation actually mean on each target, and fixes
the one boundary that keeps the choice reversible. An Android-only or Desktop-only graph is
`nav-compose`, whose type-safe route rules apply here unchanged.

> **Related skills:**
> - `nav-compose` — the single-target graph, and the Navigation Compose API the JetBrains port mirrors
> - `nav-deeplinks` — the URL half, and the typed Route it hands to whichever library below you picked
> - `arch-mvvm` — the layer that emits a route and must never call a navigation library itself
> - `compose-state` — `rememberSaveable` and `SaveableStateHolder`, and what each of them survives
> - `pkg-kmp-source-sets` — where the `Navigator` interface and its per-host implementations sit
> - `di-koin` — binding one `Navigator` implementation per platform module, which is the swap point
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

## The Three Options

| | `org.jetbrains.androidx.navigation:navigation-compose` | Decompose | Voyager |
|---|---|---|---|
| Model | `NavController` + `NavHost`, the same API as Android's | a tree of components, each with a `ComponentContext`; `childStack` driven by `StackNavigation` | screens as objects, held in a `Navigator`'s list |
| Typed destinations | `@Serializable` routes, exactly as in `nav-compose` | a `@Serializable` sealed `Config` per stack | the `Screen` object carries its own arguments |
| Needs Compose | yes | no — the component tree is plain Kotlin, a UI is attached to it | yes |
| Lifecycle & retention | Compose's, plus the multiplatform `ViewModel` | its own: `Lifecycle`, `StateKeeper`, `InstanceKeeper`, `BackHandler` (Essenty) | `ScreenModel`, retained by the `Navigator` |
| Nested / parallel stacks | nested graphs, one active stack | native to the model: a component owns children | one `Navigator` per nesting level |
| Maturity | youngest of the three; iOS and web support still maturing | mature and steadily released | simplest to adopt; maintenance cadence is slower than the other two |

1. **Take `navigation-compose` when the team already knows Navigation Compose** and every target
   renders with Compose Multiplatform. The API, the typed routes and every rule in `nav-compose`
   transfer, so a shared screen and an Android-only screen are written the same way. Pin the version
   and read the release notes: this is where the port is still moving.
2. **Take Decompose when navigation must exist without a UI.** Its stack is a tree of plain Kotlin
   components, so it is testable with no Compose runtime, it survives a screen being rendered by the
   platform's own UI toolkit instead of Compose, and nested or parallel stacks (a tab holding its own
   stack, a dialog as a component) are the model rather than a workaround. The cost is ceremony:
   every component takes a `ComponentContext`, and retention is something you declare.
3. **Take Voyager when the app is small and the stack is a list of screens.** A `Screen` object and a
   `Navigator` is all there is to learn. Weigh it with open eyes: its release cadence is slower than
   the other two, so treat "the version we pinned is the version we have for a while" as part of the
   decision rather than as a surprise.
4. **One library per app.** Two of them means two back stacks, and system back reaches one of them.
   Rule: whichever you pick, hide it behind the `Navigator` below, so the day the pick is wrong the
   damage is one module.

**When in doubt**, and the app is Compose everywhere with an Android-shaped team, start with
`navigation-compose`. Reach for Decompose the moment a non-Compose UI host or a genuinely nested
stack is on the roadmap — retrofitting the component tree later is the expensive direction.

## Back Handling

Back is not one gesture. It is three different platform facts sharing a name:

| Target | What "back" is | What the library must map |
|---|---|---|
| Android | the system back button and the predictive-back gesture | `OnBackPressedDispatcher`, surfaced to Compose as `BackHandler` |
| iOS | the edge swipe and the navigation bar's back control | both, and the swipe wants a live progress preview to feel right |
| Desktop | nothing — there is no system back | the app draws it: a toolbar arrow, an `Esc` binding, a mouse side button |

1. **One back abstraction in `commonMain`, and every screen calls it.** Compose Multiplatform ships
   one since 1.8 — `BackHandler` and `PredictiveBackHandler` from `androidx.compose.ui.backhandler`,
   in `org.jetbrains.compose.ui:ui-backhandler`, a separate dependency the `commonMain` source set
   declares. Still experimental: pin the version and expect the import path to move once more.

```kotlin
// commonMain
@Composable
fun EditorScreen(state: EditorState, onDiscard: () -> Unit, onBack: () -> Unit) {
    BackHandler(enabled = state.hasUnsavedChanges) { onDiscard() }
    EditorScaffold(state = state, onBack = onBack)
}
```

2. **Decompose brings its own**, from Essenty, plus `PredictiveBackGestureOverlay` — which draws the
   edge-swipe preview on every target, including the ones whose OS has no such gesture. If the app
   is on Decompose, use that one and do not mix in the Compose Multiplatform handler.
3. **On desktop the handler never fires**, so a screen that is only escapable through back is a
   screen with no exit. Every back path also needs a drawn control, and that control calls the same
   `onBack` lambda the handler does.
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

```kotlin
// commonMain — the vocabulary, and the only navigation type shared business code sees
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

```kotlin
// the UI host's source set — one implementation per library, bound once
class NavHostNavigator(private val controller: NavHostController) : Navigator {
    override fun navigate(route: Route) { controller.navigate(route) }
    override fun back() { controller.popBackStack() }
}
```

1. **A ViewModel or use case in `commonMain` depends on `Navigator`, never on a library.** It either
   calls `navigator.navigate(Route.OrderDetail(id))` or emits the `Route` as an effect the UI turns
   into that call — the effect channel's shape is `arch-mvvm`'s, and the choice between the two is
   the same one `nav-compose` states for a single target.
2. **`Route` is the shared vocabulary**, and it is the type `nav-deeplinks` produces from a URL. One
   sealed hierarchy, one place a new screen is added, one thing a test constructs.
3. **The implementation belongs to the UI host, not to `commonMain`.** With Compose Multiplatform
   everywhere it can sit in `commonMain` too; a Decompose one wraps `StackNavigation<Config>`, and a
   host that draws its own screens gets its own. `pkg-kmp-source-sets` decides which source set.
4. **Bind it once per platform module** — one `single<Navigator>` in `di-koin` terms. That binding
   is the swap point everything in the comparison table above was chosen against.
5. **Voyager also has a type called `Navigator`.** Import-alias the library's one inside its
   implementation file; do not rename the interface. Its name is the app's vocabulary and it is the
   same word on every target.
6. **Keep the interface at two functions.** `navigate` and `back` carry almost everything; add a
   third for a real flow (reset the stack after sign-out) when one appears. A method per screen has
   turned the interface into the graph, and the graph now lives in `commonMain` again.

## Common Mistakes

1. **A library type in `commonMain` business code** — a ViewModel holding a `NavHostController`, a
   `ComponentContext`, or Voyager's `Navigator`. The shared module now compiles only where that
   library does, and swapping it means editing every ViewModel: exactly the cost the interface above
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
