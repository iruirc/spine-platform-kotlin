---
name: nav-deeplinks
description: "Use when wiring deep links into a Kotlin app — Android App Links vs custom schemes, intent filters and assetlinks.json, the URL → typed Route parser, entry points (launcher Intent, onNewIntent, notification, widget, NavDeepLink), cold-start buffering behind auth, Compose Desktop URL scheme registration, and testing with adb. Owns the URL→Route mechanics; hands the Route to nav-compose or nav-multiplatform."
---

# Deep Links

The entry side of navigation: which link type the app claims and how it proves the claim, the one
function that turns an inbound URL into a typed `Route`, every place such a URL arrives, and what
happens to a link that lands before the app is ready to honour it. What the `Route` then does — the
graph it is registered in, the back stack it pushes — belongs to `nav-compose` and
`nav-multiplatform`; this skill stops the moment a valid `Route` exists.

> **Related skills:**
> - `nav-compose` — the graph the Route lands in, and the `navDeepLink<T>` registration on the destination side
> - `nav-multiplatform` — the `Navigator` interface the router calls, and the shared `Route` hierarchy the parser produces
> - `arch-mvvm` — the effect channel a screen already uses to ask for navigation, which a replayed Route reuses
> - `compose-state` — `rememberSaveable` and `SavedStateHandle`, the two lifetimes the pending route chooses between
> - `net-architecture` — loading the object a link only names, and the session state the gate reads before replaying
> - `release-ops` — the signing certificate behind `sha256_cert_fingerprints`, and the packaging that registers a desktop scheme
> - `architecture-choice` — the compass that names this skill as soon as a project has any inbound link at all

## When to Use

- A URL, a notification tap, a shortcut or a widget has to open a specific screen
- User asks "why does my link open the browser instead of the app", "why does the chooser dialog
  appear", "why does the link work when the app is open and not when it is killed", "how do I send
  someone to a screen behind login", "how do I open a Compose Desktop app from a URL"
- Review finds `intent.data` read inside `onCreate` with a `when` over `path` next to it, or a
  `navController.navigate(...)` reachable before the `NavHost` has composed
- An OAuth or payment provider needs a redirect URL and nobody has decided which kind it is

Not for the graph itself, the argument types or the back stack (`nav-compose`, `nav-multiplatform`),
and not for push delivery — what a notification carries in its payload and how it is built is
`release-ops-android`; this skill starts at the URL inside it.

`references/detailed-guide.md` lies beside this file; its `## Contents` names the sections — read only the ones the table points to.

## When To Load The Reference

| Need | Reference sections |
|---|---|
| Where `Route` and `PendingRoute` are declared, and why they are not repeated here | `Shared Types` |
| Intent filter and the hosted `assetlinks.json` | `App Links Setup` |
| Prove the link verified on a real device | `Verification On Device` |
| Write the URL → Route parser | `The Parser` |
| The table test that is the parser's whole contract | `The Parser Test` |
| Cold start, `onNewIntent`, and the `launchMode` consequence | `Entry Points — Activity` |
| Let Navigation Compose match the URL itself | `Entry Points — NavDeepLink` |
| `PendingIntent` for a notification, a shortcut, a widget | `Entry Points — Notifications, Shortcuts, Widgets` |
| Buffer a link behind an auth or onboarding gate | `Pending Route Gate` |
| Open a Compose Desktop app from a URL | `Desktop Scheme Registration` |
| The `adb` recipes for both halves | `Testing With adb` |

## Core Shape

```
inbound URL          intent data · onNewIntent · notification · shortcut · widget
      |
      v
DeepLinkParser.parse(url: String): Route?        pure, no framework, one table test
      |
      v
DeepLinkRouter                                   asks the gate, holds at most one Route
      |
      +-- not ready / behind a gate --> PendingRoute (SavedStateHandle) --+
      |                                                                   |
      v                                                          replayed once
Navigator.navigate(route)  /  NavController inside the Route composable
      |
      v
nav-multiplatform · nav-compose
```

The `Route` is the one from the graph — `nav-multiplatform`'s hierarchy in `commonMain`, and the
same types `nav-compose` registers:

```kotlin
@Serializable
sealed interface Route {
    @Serializable data object Home : Route
    @Serializable data class OrderDetail(val id: String) : Route
    @Serializable data class Search(val query: String? = null) : Route
}

object DeepLinkParser {
    fun parse(url: String): Route? {
        val u = runCatching { Url(url) }.getOrNull() ?: return null  // io.ktor.http.Url
        val ours = when (u.protocol.name) {          // scheme and host together, never one alone
            "https" -> u.host in setOf("example.com", "www.example.com")
            "myapp" -> u.host == "app"
            else -> false
        }
        if (!ours) return null
        val path = u.segments.filter(String::isNotEmpty)
        return when {
            path.isEmpty() -> Route.Home
            path.size == 2 && path[0] == "orders" && path[1].isOrderId() -> Route.OrderDetail(path[1])
            path.size == 1 && path[0] == "search" -> Route.Search(u.parameters["q"])
            else -> null
        }
    }
}
```

**The parser takes a `String`, never an `android.net.Uri`.** The framework class is a stub on the
JVM unit-test classpath — `Uri.parse` throws "not mocked" unless the module turns on default return
values or pulls in Robolectric — so a parser typed against it drags an instrumented harness into the
one class that most deserves a plain table test. A `String` also keeps the parser in `commonMain`.
Parse it with `io.ktor.http.Url` when the project already has a Ktor client (`net-http-clients`), or
with `java.net.URI` in a JVM-only app; hand-splitting is a third option and a worse one, because
percent-encoding and query parsing are exactly where hand-rolled code is wrong.

## Rules

1. **Every surface ends at the same call.** Each entry point produces a URL string and hands it to
   one router. Two parse sites drift apart within a release, and the disagreement is reported as
   "the link works from the notification and not from the widget".
2. **The parser is pure.** No `Context`, no `NavController`, no repository, no suspension. It is the
   only part of this skill that needs heavy testing, and it earns that by being a function.
3. **Unknown is `null`, and `null` is a decision.** An old link from two releases ago must land on
   the start destination, not on a crash and not on a blank screen. `null` never escapes as an
   exception out of `onCreate`.
4. **Nothing in a URL is trustworthy.** Check the host, check the shape of every id, and never let
   a link alone perform an authenticated or destructive action — it may open the confirmation
   screen, never the confirmed result.
5. **The link names, the app loads.** A route argument carries an id; the screen fetches the object
   through the repository (`net-architecture`). A URL is public, size-capped and stale by the time
   it is opened, which is `nav-compose`'s rule about route arguments arriving from outside.
6. **Routing stops at the `Navigator`.** The router produces a `Route` and hands it to the
   `Navigator` (`nav-multiplatform`) or to the `NavController` the Route composable owns
   (`nav-compose`). Moving the destination decision here puts a second copy of the graph in the
   link layer.
7. **Ship the `https` link as the user-facing one.** Keep a custom scheme for internal callbacks and
   QA, and never carry a token, an auth code or anything else secret on it.
8. **Verification is a release artifact, not a code change.** The intent filter, the hosted file and
   the signing certificate have to agree, and only a device check proves they do.

## Link Type Decision

| | Android App Link (`https://`) | Custom scheme (`myapp://`) |
|---|---|---|
| Declared by | intent filter over an `https` `<data>` with `android:autoVerify="true"` | intent filter over `<data android:scheme="myapp">` |
| Proof of ownership | `.well-known/assetlinks.json` on the domain — HTTPS, `application/json`, no redirect, `sha256_cert_fingerprints` matching the signing key | none: any installed app may declare the same scheme |
| App not installed | the same URL opens in the browser and shows the page | nothing happens — dead text in every messenger |
| Opens without a chooser | yes, once verified | no — Android disambiguates between every claimant |
| Verified state visible | `adb shell pm get-app-links <package>` | not a concept |
| OAuth / payment redirect | the recommended target; still needs PKCE | interceptable by design — another app can register the scheme and receive the code |
| Use for | everything a user can receive, share, or click outside the app | callbacks and click targets inside your own app, QA, local tooling |

**Default to App Links for anything that leaves the app.** Register the custom scheme too if
something internal needs it, and let one parser turn either spelling into the same `Route` — the
scheme is an input format, not a second feature.

**Compose Desktop has no App Links.** The OS matches a custom scheme that the *installer*
registered, so the decision above collapses to one option and moves into packaging: `Info.plist` on
macOS, a registry key on Windows, a `.desktop` file on Linux. See `Desktop Scheme Registration` in
the reference, and `release-ops` for the distribution that carries it.

## Entry Points

Every row ends at the same `DeepLinkParser.parse` call.

| Entry point | Arrives as | Note |
|---|---|---|
| Cold start from a link | `Activity.intent.data` read in `onCreate` | the same intent is re-delivered to the recreated Activity, so consume it once |
| Warm start, app already running | `onNewIntent(intent)` | fires only under `launchMode="singleTop"` or `singleTask`; call `setIntent(intent)` so later reads are not the stale one |
| Navigation Compose's own matching | `navDeepLink<T>(basePath = …)` on the destination (`nav-compose`) | it matches the URL and synthesises the back stack for you |
| Notification tap | `PendingIntent` wrapping a `VIEW` intent | `FLAG_IMMUTABLE` **or** `FLAG_MUTABLE` is required of an app targeting API 31+ |
| App Shortcut | `res/xml/shortcuts.xml`, or `ShortcutManagerCompat` for a dynamic one | each `<intent>` is a `VIEW` action over the app's own URL |
| App widget | `RemoteViews.setOnClickPendingIntent` | same `PendingIntent` shape, same flags |

**Let `navDeepLink<T>` do it when the URL maps to exactly one destination with no gate and no
rewrite** — the library then matches the pattern, fills the typed arguments and builds the parent
chain, and there is nothing left for a parser to add. **Route through the parser instead** when any
of these is true: the destination depends on a value the URL does not contain (a role, a feature
flag, an experiment), the link must wait behind sign-in or onboarding, one URL has to be rewritten
to a different destination as the product changes, or the same link arrives from a surface that is
not an `Intent` at all. Mixing is normal and harmless as long as each URL shape has exactly one
owner; two owners for one shape is a race whose winner changes with the graph.

## Cold Start & Pending Route

The bug this section exists for: the link works while the app is open and does nothing from a killed
app, because it arrived before the graph existed or before the app knew who was signed in.

```kotlin
// survives process death because SavedStateHandle does; the Route is @Serializable already
class PendingRoute(private val handle: SavedStateHandle) {
    fun hold(route: Route) { handle[KEY] = Json.encodeToString(route) }
    fun consume(): Route? = handle.remove<String>(KEY)?.let { Json.decodeFromString<Route>(it) }

    private companion object { const val KEY = "pending_route" }
}
```

1. **Hold at most one.** A second link arriving before the gate opens replaces the first — the user
   clicked the newer one and is not waiting for both.
2. **The gate is app state, not a delay.** It opens when the graph has composed *and* the session
   has resolved to a definite answer (signed in, signed out — never "still loading") *and*
   onboarding is finished. A `delay(300)` in place of that condition is the same bug with a timer.
3. **Consume, do not read.** `remove`, not `get`: a rotation after the replay must not navigate a
   second time, and the second copy of the detail screen on the back stack is how you find out.
4. **Gate per route, not per app.** A public link should not wait for the session to resolve; only
   the routes that need an identity do.
5. **Drop it when the gate closes for good.** If the user abandons sign-in, the pending route dies
   with the attempt — replaying it at the start of the next session is navigation the user did not
   ask for and cannot explain.
6. **Reset or preserve the existing back stack is a product decision**, not a default: a link
   arriving mid-checkout either interrupts it or queues behind it. Capture the answer in
   `spine-toolkit:feature-requirements` before writing either one.

## Testing

```bash
# the app half: does this URL become that screen
adb shell am start -W -a android.intent.action.VIEW -d "https://example.com/orders/42" com.example.app
# the system half: drop the package and see who Android actually gives the link to
adb shell am start -W -a android.intent.action.VIEW -d "https://example.com/orders/42"
adb shell pm get-app-links com.example.app
```

1. **The parser is a table test and needs no device.** One list of URL → expected `Route?`, covering
   both URL shapes, an unknown path, a wrong host, a missing and an extra segment, an encoded
   segment, and outright garbage. This is the test that pays for the whole design.
2. **The gate is a unit test too.** Construct `PendingRoute` over a plain `SavedStateHandle`, hold a
   route, open the gate, assert it replays exactly once and is gone afterwards.
3. **`adb ... -d <url> <package>` proves parsing; the same command without the package proves
   verification.** Naming the package bypasses the chooser, so a filter that was never verified
   passes the first command and fails the second — which is the failure users report.
4. **`pm get-app-links` is the only honest verification check** (API 31+). It prints a state per
   host, and anything other than `verified` means the link opens a browser on a clean device.
   Re-run it after `adb shell pm verify-app-links --re-verify com.example.app`.
5. **The graph half is `nav-compose`'s** — `TestNavHostController`, `hasRoute<T>()`. Test that the
   parsed `Route` reaches the destination there, once per feature, not once per URL.
6. **A `PendingIntent` is opaque to a test.** Build the `Intent` in a named function, assert on that
   function, and let the wrapping be one untested line.
7. **Put link verification on the release checklist.** It depends on the signing key and on a file
   someone else deploys, so it breaks between releases with no code change:
   `spine-toolkit:ops-checklist`.

## Common Mistakes

1. **Trusting the host without verification.** The code checks `host == "example.com"` and calls the
   link trusted, while the manifest has no `android:autoVerify="true"` or the hosted file is
   unreachable. Android then treats the filter as an ordinary claim: a chooser appears, another app
   can be picked, and the "verified" domain proved nothing. `pm get-app-links` is the check, and it
   has to say `verified` on a freshly installed release build.
2. **Parsing in the Activity.** A `when (intent.data?.path)` ladder in `onCreate`. It cannot be unit
   tested without an instrumented harness, it grows a second copy the day a notification is added,
   and the two copies disagree about trailing slashes before anyone notices.
3. **Navigating before the graph exists.** `navController.navigate(route)` from `onCreate`, from a
   `LaunchedEffect` above the `NavHost`, or from a callback that fires while the destination is
   still unregistered — an `IllegalArgumentException` naming a destination that is about to exist.
   The gate's first condition is that the graph has composed.
4. **`launchMode="standard"` with `onNewIntent` code.** The override never runs; every link stacks a
   fresh Activity instance on top of the old one, and back goes through a museum of them. The mirror
   image is an `onNewIntent` that reads `getIntent()` instead of its parameter and routes to the
   link before last.
5. **A `PendingIntent` with neither `FLAG_IMMUTABLE` nor `FLAG_MUTABLE`.** An app targeting API 31
   or later throws, and it throws where the notification is built rather than where the link is
   handled, so the stack trace blames the wrong feature.
6. **Re-navigating on every configuration change.** The launch intent is re-delivered to the
   recreated Activity, so a rotation on a deep-linked screen pushes a second copy of it. The intent
   has to be consumed once and marked as consumed in saved state.
7. **A secret on a custom scheme.** An OAuth code or a session token delivered to `myapp://callback`
   — any installed app may register that scheme and receive it. The redirect target is an App Link,
   and PKCE is not optional on either.
8. **Payload instead of an id.** A whole order serialized into the URL, so the screen renders
   yesterday's prices, the link breaks the first time a field is added, and the data is now visible
   in every chat log that carried it.
9. **`assetlinks.json` that does not serve.** Behind a redirect, with `text/plain`, on `www.` while
   the filter names the apex host, or listing only the debug fingerprint so no release build ever
   verifies. Nothing in the app changes when this breaks, which is why it is found by users.
10. **A retired URL shape crashing the app.** The path removed in the last release is still sitting
    in emails, chat logs and search results, and it has to open the start destination like any
    other unrecognised link.
11. **A parser test with only the happy rows.** Empty paths, a missing query parameter, a
    percent-encoded slash, an id that is not an id: the rejected half of the table is the half that
    describes what actually arrives.
