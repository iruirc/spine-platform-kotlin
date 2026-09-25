# nav-deeplinks — detailed guide

## Contents

- Shared Types
- App Links Setup
- Verification On Device
- The Parser
- The Parser Test
- Entry Points — Activity
- Entry Points — NavDeepLink
- Entry Points — Notifications, Shortcuts, Widgets
- Pending Route Gate
- Desktop Scheme Registration
- Testing With adb

## Shared Types

The `Route` hierarchy and the `PendingRoute` holder are printed once, in this skill's `SKILL.md`, and
referred to from here rather than copied — two copies of a type is two places to change it.

## App Links Setup

An App Link is two artifacts that must agree: an intent filter in the app, and a file on the domain.
Neither one alone does anything.

```xml
<!-- src/main/AndroidManifest.xml — the MAIN/LAUNCHER filter is unchanged and omitted -->
<activity android:name=".MainActivity" android:exported="true" android:launchMode="singleTop">

    <!-- verified against https://example.com/.well-known/assetlinks.json -->
    <intent-filter android:autoVerify="true">
        <action android:name="android.intent.action.VIEW" />
        <category android:name="android.intent.category.DEFAULT" />
        <category android:name="android.intent.category.BROWSABLE" />
        <data android:scheme="https" android:host="example.com" />
        <data android:scheme="https" android:host="www.example.com" />
        <data android:pathPrefix="/orders" />
        <data android:pathPrefix="/search" />
    </intent-filter>

    <!-- custom scheme: never verified, so never given anything secret -->
    <intent-filter>
        <action android:name="android.intent.action.VIEW" />
        <category android:name="android.intent.category.DEFAULT" />
        <category android:name="android.intent.category.BROWSABLE" />
        <data android:scheme="myapp" android:host="app" />
    </intent-filter>
</activity>
```

1. **`DEFAULT` and `BROWSABLE` are both required**, and `android:exported="true"` with them — a link
   from a browser or a messenger matches none of it otherwise, and from API 31 the build fails.
2. **Sibling `<data>` elements merge into a cross-product** inside one filter — every scheme with
   every host with every path. That is why the custom scheme sits in its own filter: left in the
   verified one it would inherit `example.com` and be verified against a file it can never match.
3. **`www.example.com` and `example.com` are two hosts**, both declared and both needing the file
   (the same bytes on both is fine). Keep hosts you cannot serve it for out of the `autoVerify`
   filter: before Android 12 one unreachable host failed every domain the app declared, and from
   Android 12 a staging host with no file is still a permanent failure line in the per-host state.

The file, served at `https://example.com/.well-known/assetlinks.json`:

```json
[
  {
    "relation": ["delegate_permission/common.handle_all_urls"],
    "target": {
      "namespace": "android_app",
      "package_name": "com.example.app",
      "sha256_cert_fingerprints": [
        "14:6D:E9:83:C5:73:06:50:D8:EE:B9:95:2F:34:FC:64:16:A0:83:42:E6:1D:BE:A8:8A:04:96:B2:3F:CF:44:E5"
      ]
    }
  }
]
```

1. **HTTPS, HTTP 200, `Content-Type: application/json`, and no redirect.** Android does not follow a
   redirect when it fetches this file — not apex to `www`, not `http` to `https`. A CDN rule that
   normalizes trailing slashes has broken more App Links than any code change.
2. **One fingerprint per key that will ever sign a build that opens the link.** With Play App
   Signing that is at least two: the upload key and Play's re-signing key (`release-ops`). A local
   one comes from `keytool -list -v -keystore release.jks -alias upload` or `./gradlew signingReport`;
   a `debug` build with its own `applicationId` is a different app and needs its own entry or host.
3. **Verification runs at install time and needs the network.** A device that installed the app
   offline reports the domain unverified until something re-verifies it.
4. **The file is a deploy artifact of the website, not of the app.** It breaks with no code change,
   which is why `Verification On Device` belongs on the release checklist and not in a test suite.

## Verification On Device

Every `pm` subcommand below is API 31+: the per-domain verification state does not exist before
Android 12, and on an older device tapping the link is the only check there is.

```bash
adb shell pm get-app-links com.example.app
```

```
com.example.app:
    Domain verification state:
      example.com: verified
      www.example.com: 1024
```

- **`verified`** — the file was fetched and matched. Tapping the link opens the app with no chooser.
- **`none`** — the host was never checked: no network at install time, or the filter is not
  `autoVerify`.
- **`legacy_failure`** or a bare number (`1024`, `4096`, …) — the check ran and failed. The number is
  a platform failure code, not a state to aim at; treat every one of them as "the link opens a
  browser".

```bash
# re-run verification (device online, app installed), then read the state again
adb shell pm verify-app-links --re-verify com.example.app

# approve the host the way a user would in Settings — for testing routing
# while the hosted file is not deployed yet. It proves nothing about verification.
adb shell pm set-app-links-user-selection --user cur --package com.example.app true example.com
```

Verification is asynchronous: `get-app-links` right after `--re-verify` can still show the old
state. From outside the device, `curl -sSI https://example.com/.well-known/assetlinks.json` proves
the status, the content type and the absence of a `Location:` header in one line, and the public
`digitalassetlinks.googleapis.com/v1/statements:list` endpoint shows what the resolver sees — an
empty statement list being the usual answer when the app opens a browser.

## The Parser

The whole trust boundary in one file. Everything downstream may assume a `Route` it receives is
well-formed, because this is where an ill-formed one became `null`.

<!-- compile: android -->
```kotlin
// commonMain/kotlin/com/example/app/deeplink/DeepLinkParser.kt
// Route is the sealed hierarchy in SKILL.md's Core Shape
package com.example.app.deeplink

import io.ktor.http.Url

object DeepLinkParser {

    private val webHosts = setOf("example.com", "www.example.com")
    private val orderId = Regex("^[0-9]{1,12}$")
    private const val MAX_QUERY = 200

    fun parse(raw: String): Route? {
        // a URL the library cannot parse is just an unknown link; nothing here suspends,
        // so this is not the runCatching trap error-architecture warns about
        val url = runCatching { Url(raw) }.getOrNull() ?: return null
        val ours = when (url.protocol.name) {
            "https" -> url.host in webHosts
            "myapp" -> url.host == "app"
            else -> false
        }
        if (!ours) return null

        val path = url.segments.filter(String::isNotEmpty)
        return when {
            path.isEmpty() -> Route.Home
            path.size == 2 && path[0] == "orders" && orderId.matches(path[1]) -> Route.OrderDetail(path[1])
            path.size == 1 && path[0] == "search" -> Route.Search(url.parameters["q"]?.take(MAX_QUERY))
            else -> null
        }
    }
}
```

1. **The custom scheme gets a fixed host on purpose.** In `myapp://orders/42` the authority is
   `orders` and the path is `/42`: the first segment silently becomes the host, and a parser written
   against the `https` shape mismatches every custom-scheme link. Declaring `myapp://app/...` in the
   manifest and checking `host == "app"` makes both shapes produce the same segment list.
2. **`http` is not `https`**, and the `when` rejects it because the intent filter never declared it.
3. **Every id is shape-checked and every free-text field is bounded.** `orderId` is what stops a
   traversal segment and a 4 MB id from reaching a repository; `take(MAX_QUERY)` does the same for
   input that has no shape at all. `Route.Home` for the bare host is reachable only through the
   custom scheme or `am start` — the filter's `pathPrefix` list never delivers the apex — but the
   branch costs one line and keeps a hand-built URL from looking broken.

**Without Ktor on the classpath**, on a JVM-only target, `java.net.URI` does the same job with more
hand-work and one trap of its own: split `url.rawPath`, not `url.path`, and run
`URLDecoder.decode(…, UTF_8)` over each segment **after** the split — `path` is already decoded, so
an encoded `%2F` inside a segment has become a separator by the time you see it, which is the trap
`The Parser Test` keeps a row against. The query is the same story from `rawQuery`: split on `&`,
then on `=`, then decode each half. That hand-work is the argument for the Ktor form wherever the
project already has it (`net-http-clients`) — percent-encoding and repeated keys are where
hand-written parsing goes wrong, and it goes wrong on the untrusted input path.

The Android edge is the only Android-typed line in the feature:

<!-- compile: android -->
```kotlin
import android.content.Intent

fun Intent.deepLinkUrl(): String? = takeIf { it.action == Intent.ACTION_VIEW }?.data?.toString()
```

Every parsed link goes to one ViewModel, which owns the `PendingRoute` and so the only handle that
outlives the process. It holds the link and never navigates: the graph replays it, passing in the
gate and the navigation call, so no `NavController` or `Navigator` reaches the ViewModel
(`nav-compose` → "The Boundary"):

<!-- compile: android -->
```kotlin
class DeepLinkViewModel(handle: SavedStateHandle) : ViewModel() {
    private val pending = PendingRoute(handle)
    val held: StateFlow<String?> = pending.held

    // an unknown link holds nothing, and the app opens as usual
    fun handle(url: String) { DeepLinkParser.parse(url)?.let(pending::hold) }

    fun replay(gate: DeepLinkGate, navigate: (Route) -> Unit) {
        val route = pending.consume() ?: return
        if (gate.allows(route)) navigate(route) else pending.hold(route)
    }

    fun drop() = pending.drop()
}
```

## The Parser Test

The table is the contract. It runs in `commonTest` with no device, no Robolectric and no graph —
which is the entire reason `parse` takes a `String`.

<!-- compile: android-test -->
```kotlin
class DeepLinkParserTest {

    private val cases = listOf(
        // accepted
        "https://example.com/orders/42" to Route.OrderDetail("42"),
        "https://www.example.com/orders/42" to Route.OrderDetail("42"),
        "https://example.com/orders/42/" to Route.OrderDetail("42"),
        "myapp://app/orders/42" to Route.OrderDetail("42"),
        "https://example.com/orders/4%32" to Route.OrderDetail("42"),   // decoded, then shape-checked
        "https://example.com/search?q=t%C3%A4isch" to Route.Search("täisch"),
        "https://example.com/search" to Route.Search(null),
        "https://example.com/" to Route.Home,
        // rejected
        "https://evil.example.org/orders/42" to null,
        "http://example.com/orders/42" to null,
        "https://example.com/orders" to null,
        "https://example.com/orders/42/items" to null,
        "https://example.com/orders/%2E%2E%2Fadmin" to null,
        "myapp://orders/42" to null,
        "" to null,
        "not a url at all" to null,
    )

    @Test
    fun parse_everyCase_mapsKnownShapeToRouteAndRestToNull() {
        val failures = cases.mapNotNull { (url, expected) ->
            val actual = DeepLinkParser.parse(url)
            "$url -> $actual, expected $expected".takeIf { actual != expected }
        }
        assertTrue(failures.isEmpty(), failures.joinToString("\n"))
    }
}
```

1. **One assertion over the whole table, not one test per row.** The failure message names every
   row that broke, so one run says whether a change moved one case or the grammar. A JUnit 5
   `@ParameterizedTest` or a Kotest `withData` block trades that for per-row reporting; either is
   fine, one list is not optional.
2. **The rejected half is the half that matters** — a look-alike host, the wrong scheme, a truncated
   path, a traversal attempt, a partly-encoded segment. Decoding happens before the shape check:
   `%C3%A4` arrives as `ä` and `%2E%2E%2F` as `../`, and a parser that matches the raw segment and
   decodes afterwards passes the traversal straight through.
3. **Add the row before the fix**, and test nothing else here. Whether the `Route` reaches the screen
   is the graph's test (`nav-compose`); whether it waits is the gate's.

## Entry Points — Activity

The two Activity callbacks, and the guard that keeps a rotation from navigating twice.

<!-- compile: android -->
```kotlin
import android.content.Intent
import androidx.activity.viewModels
import org.koin.android.ext.android.inject

class MainActivity : ComponentActivity() {

    private val deepLinks: DeepLinkViewModel by viewModels()
    private val sessions: SessionRepository by inject()   // di-koin; di-hilt injects the same object

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // the launch intent is re-delivered to every recreation; a link held before it is in the handle
        if (savedInstanceState == null) intent.deepLinkUrl()?.let(deepLinks::handle)
        setContent { App(deepLinks, sessions.session) }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)                  // so any later getIntent() is not the stale one
        intent.deepLinkUrl()?.let(deepLinks::handle)
    }
}
```

`onNewIntent` runs only when the system reuses the existing instance. The manifest decides that, and
so does the sender: an intent carrying `FLAG_ACTIVITY_SINGLE_TOP` gets `singleTop` behaviour for that
one launch.

| `launchMode` | A link arriving while the app is already running |
|---|---|
| `standard` (default) | a **new** Activity instance on top of the old one; `onNewIntent` does not fire, and back walks a pile of duplicates |
| `singleTop` | reused when it is already at the top of the task → `onNewIntent`; a new instance otherwise |
| `singleTask` | always reused → `onNewIntent`, and **everything above it in the task is destroyed** first |
| `singleInstance` | as `singleTask`, alone in its own task — almost never right for an app with a back stack |
| `singleInstancePerTask` | as `singleInstance`, one instance per task (API 31+) |

1. **`singleTop` for a single-Activity Compose app.** It is the only mode that gives `onNewIntent`
   without also deciding, in the manifest, that every link wipes the back stack — and whether a
   given link resets the stack is the router's per-route decision, not a build artifact's.
2. **Read the parameter, not `getIntent()`, inside `onNewIntent`** — and call `setIntent` so a later
   reader agrees. Reading the getter first is how an app routes to the link before last.
3. **Nothing here parses.** The Activity checks `ACTION_VIEW`, extracts a `String` and calls the
   ViewModel. That is the whole of its involvement, and it is why none of this needs a device.

## Entry Points — NavDeepLink

Navigation Compose can match a URL itself, filling the typed arguments and building the parent chain
(`nav-compose` owns the graph this sits in):

```kotlin
NavHost(navController, startDestination = Route.Home) {
    composable<Route.OrderDetail>(
        deepLinks = listOf(navDeepLink<Route.OrderDetail>(basePath = "https://example.com/orders")),
    ) { entry -> OrderDetailRoute(entry.toRoute<Route.OrderDetail>()) }
}
```

1. **The intent filter is still yours to write.** `navDeepLink` teaches the graph a pattern; it does
   not add anything to the manifest, and a Kotlin-DSL graph has no `<nav-graph>` tag to generate one
   from. Without the filter of `App Links Setup`, Android never hands the app the link at all.
2. **`basePath` plus the type's fields is the pattern.** A field without a default becomes a path
   segment after the base path, a field with one becomes an optional query parameter — the same rule
   `nav-compose` states for arguments arriving from inside the app.
3. **The library reads the launch intent on first composition** and matches it, so a cold-start link
   reaches the destination with no code in the Activity; on the warm path `onNewIntent` hands it
   over with `navController.handleDeepLink(intent)`. Either way it synthesises the parent chain, so
   back returns to a real screen instead of exiting the app.
4. **Let it handle a URL when the URL fully determines the destination.** Own the URL in the parser
   instead when a gate, a rewrite or a computed destination is involved — and then register no
   `navDeepLink` for it. Two owners for one URL shape is a race whose winner moves with the graph.

## Entry Points — Notifications, Shortcuts, Widgets

All three build the same `Intent` and differ only in what wraps it.

```kotlin
/** The one place an inbound Intent is constructed. Testable; the PendingIntent around it is not. */
fun linkIntent(context: Context, url: String): Intent =
    Intent(Intent.ACTION_VIEW, url.toUri()).setPackage(context.packageName)

fun orderReadyNotification(context: Context, orderId: String): Notification =
    NotificationCompat.Builder(context, CHANNEL_ORDERS)
        .setSmallIcon(R.drawable.ic_notification)
        .setContentTitle(context.getString(R.string.order_ready))
        .setAutoCancel(true)
        .setContentIntent(
            PendingIntent.getActivity(
                context,
                orderId.hashCode(),                        // distinct request code per target
                linkIntent(context, "https://example.com/orders/$orderId"),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            ),
        )
        .build()
```

1. **`FLAG_IMMUTABLE` or `FLAG_MUTABLE` is required of an app targeting API 31 or later.** Neither
   one and the constructor throws — at the notification site, which is nowhere near the link
   handling, so the stack trace blames the wrong feature. Immutable unless something genuinely fills
   the intent in later (a direct-reply action).
2. **`setPackage(packageName)` targets your own app** regardless of verification state, so an
   in-app notification never opens a chooser and never depends on the hosted file.
3. **Give each target its own request code.** Two `PendingIntent`s are the same object when their
   request codes and their `Intent`s match on action, data, type, class and categories — extras are
   never compared. The URL differs per order here, but the request code is the guard that survives
   someone moving the id into an extra.
4. **The URL is the same one a browser would open.** One grammar, one parser, one place to change.

A static shortcut in `res/xml/shortcuts.xml`, referenced from the launcher Activity by a
`<meta-data android:name="android.app.shortcuts" android:resource="@xml/shortcuts" />`:

```xml
<shortcuts xmlns:android="http://schemas.android.com/apk/res/android">
    <shortcut android:shortcutId="search" android:enabled="true"
        android:icon="@drawable/ic_shortcut_search"
        android:shortcutShortLabel="@string/shortcut_search_short"
        android:shortcutLongLabel="@string/shortcut_search_long">
        <intent android:action="android.intent.action.VIEW"
            android:data="https://example.com/search"
            android:targetPackage="com.example.app"
            android:targetClass="com.example.app.MainActivity" />
    </shortcut>
</shortcuts>
```

A dynamic one is the same `Intent` handed to `ShortcutInfoCompat.Builder(context, "order-$id")
.setShortLabel(title).setIntent(linkIntent(context, url))` and pushed with
`ShortcutManagerCompat.pushDynamicShortcut`; the builder throws if the `Intent` carries no action
and again if `setShortLabel` was never called, and the action is `VIEW` for the same reason as
everywhere else. A widget wraps the identical `PendingIntent` once more —
`RemoteViews(context.packageName, R.layout.widget_orders).setOnClickPendingIntent(R.id.widget_root, …)`
— and with Glance it goes to `actionStartActivity(...)` instead. Nothing about the URL, the flags or
the parser changes on any of the three.

## Pending Route Gate

Links do not wait for the app: one may land before the graph exists, before the app knows who is
signed in, or halfway through onboarding. One holder, one gate, one replay.

`PendingRoute` is the holder printed in `SKILL.md`; its `drop()` clears the slot without replaying
it. It lives in `commonMain` because `lifecycle-viewmodel-savedstate` went multiplatform
in Lifecycle **2.9.0** — not 2.8, which shipped the multiplatform `lifecycle-viewmodel` and
`lifecycle-runtime-compose` and left saved state on Android. The gate beside it:

<!-- compile: android -->
```kotlin
fun interface DeepLinkGate { fun allows(route: Route): Boolean }

class SessionGate(private val session: Session) : DeepLinkGate {
    override fun allows(route: Route): Boolean = when (route) {
        Route.Home, is Route.Search -> true                       // public: no gate at all
        is Route.OrderDetail -> session is Session.SignedIn
    }
}
```

The route is stored serialized because `SavedStateHandle` holds `Bundle`-able values on Android and
the `Route` is `@Serializable` already — the same annotation `nav-compose` needs for the graph.

<!-- compile: android -->
```kotlin
@Composable
fun App(deepLinks: DeepLinkViewModel, session: StateFlow<Session>) {
    val navController = rememberNavController()
    AppNavHost(navController)
    // effects run after the composition is applied, so the NavHost above already exists here
    LaunchedEffect(deepLinks, navController) {
        combine(deepLinks.held, session) { _, current -> SessionGate(current) }
            .collect { gate -> deepLinks.replay(gate) { navController.navigate(it) } }
    }
}
```

1. **`consume`, never `get`**, and `hold` overwrites. A rotation after the replay must not navigate
   a second time — the duplicate detail screen on the back stack is how this is reported — and a
   second link arriving before the gate opens is simply the newer one.
2. **The replay runs from an effect below the `NavHost`, never from `onCreate`.** The
   `NavController` exists as soon as `rememberNavController()` returns, but a destination is
   registered only once `NavHost` has composed; navigating between those two points throws, naming a
   destination that is about to exist. The effect replays again on every new link and every session
   change, so a warm-start link and a finished sign-in take the same path.
3. **A session that is still loading is not "signed out".** `allows` returns `false` for an
   unresolved session, or every cold-start deep link bounces off the login wall.
4. **Drop it when the attempt ends.** The sign-in screen calls `deepLinks.drop()` when the user
   abandons it; a route replayed at the start of the next session is navigation nobody asked for.
5. **The gate and the replay are unit tests** over a plain `SavedStateHandle` and a `Session` — no
   Activity, no graph, no device. On Compose Desktop the handle has no disk behind it, and needs none: a desktop
   process that dies loses the link with it.

Process death is one Robolectric test. The second Activity is a new instance with a new
`ViewModelStore`, built from the first one's saved `Bundle` — what Android hands an Activity it
restores after killing the process:

<!-- compile: android-test -->
```kotlin
import org.robolectric.Robolectric

@RunWith(RobolectricTestRunner::class)
class DeepLinkProcessDeathTest {

    @Test
    fun handle_processDiesBeforeReplay_restoredViewModelReplaysRoute() {
        val first = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        val url = "https://example.com/orders/42"
        ViewModelProvider(first.get())[DeepLinkViewModel::class.java].handle(url)
        val saved = Bundle()
        first.pause().stop().saveInstanceState(saved).destroy()

        val second = Robolectric.buildActivity(ComponentActivity::class.java).setup(saved)
        var replayed: Route? = null
        ViewModelProvider(second.get())[DeepLinkViewModel::class.java]
            .replay(DeepLinkGate { true }) { replayed = it }

        assertEquals(Route.OrderDetail("42"), replayed)
    }
}
```

`ViewModelProvider(activity)` resolves exactly what `by viewModels()` does in `MainActivity`. Build
the ViewModel over `SavedStateHandle()` instead — the handle a DI container hands out — and the
second Activity replays nothing.

## Desktop Scheme Registration

There is no desktop App Link. The OS matches a custom scheme that the **installer** registered, so
the whole subject is packaging — `release-ops` owns the distribution this rides in.

**`jpackage` has no URL-scheme option on any OS.** What it does have:

| Option | What it actually does |
|---|---|
| `--file-associations <file>` | registers *file types* — a different registry from URL schemes on all three systems, and no help here |
| `--resource-dir <dir>` | overrides jpackage's own templates — `Info.plist`, the WiX `main.wxs`, the `.desktop` file. **The Compose Gradle plugin sets this option itself and exposes no DSL key for it**, so a Compose Desktop build cannot take that route at all |
| `--mac-package-identifier`, `--mac-sign`, `--win-menu`, `--win-per-user-install`, `--linux-shortcut`, `--linux-menu-group`, … | identity, signing, menu entries, install scope. `--linux-shortcut` does emit a `.desktop` file — without a `MimeType` line |

**macOS — `CFBundleURLTypes` in `Info.plist`.** The Compose Desktop Gradle plugin writes it without
a template override:

```kotlin
compose.desktop.application.nativeDistributions.macOS {
    bundleID = "com.example.app"
    infoPlist {
        extraKeysRawXml = """
            <key>CFBundleURLTypes</key>
            <array><dict>
              <key>CFBundleURLName</key><string>com.example.app.deeplink</string>
              <key>CFBundleURLSchemes</key><array><string>myapp</string></array>
            </dict></array>
        """
    }
}
```

The scheme is picked up when the bundle is first launched from a location Launch Services scans —
installed, not run out of a build directory.

**Windows — a registry key.** `HKEY_CLASSES_ROOT\myapp` (or `HKCU\Software\Classes\myapp` per user)
with an empty-valued `URL Protocol` entry and
`shell\open\command` = `"C:\Program Files\ExampleApp\ExampleApp.exe" "%1"`. Nothing reachable from
the Gradle DSL writes it, so there are two workable routes: the app writes the key under `HKCU` on
first run (per user, no elevation), or the build uses a packager other than jpackage that declares
schemes itself. `release-ops` picks between them.

**Linux — a `.desktop` file** with `MimeType=x-scheme-handler/myapp;` and `Exec=exampleapp %u`. Same
constraint and the same two routes: write it to `~/.local/share/applications/` on first run and call
`update-desktop-database` on that directory, or let another packager emit it. The file
`--linux-shortcut` produces carries no `MimeType` line and there is no reachable template to add one
to.

Receiving the URL is not symmetric either, and the registration has to happen before the UI does:

```kotlin
fun main(args: Array<String>) {
    val sessions = SessionRepository(/* … */)
    val deepLinks = DeepLinkViewModel(SavedStateHandle())
    // macOS: register before application { }. A handler installed from a composition effect is
    // too late — the launch-time OpenURIEvent has already been delivered and dropped.
    if (Desktop.isDesktopSupported()) {  // getDesktop() throws where it is not, a headless JVM for one
        val desktop = Desktop.getDesktop()
        if (desktop.isSupported(Desktop.Action.APP_OPEN_URI)) {
            desktop.setOpenURIHandler { deepLinks.handle(it.uri.toString()) }
        }
    }
    args.firstOrNull()?.let(deepLinks::handle)   // Windows and Linux only: macOS passes no arguments
    application { Window(onCloseRequest = ::exitApplication) { App(deepLinks, sessions.session) } }
}
```

Even registered this early, **launch-time delivery on macOS is unreliable** — the JDK bug for it,
JDK-8198549, is still open — so the app has to tolerate losing the very first link and opening at
its start destination instead. A link arriving at an already-running app comes through the handler
dependably; `args` is no fallback, because macOS passes none.

On Windows and Linux the link instead opens a **new process** with the URL in `args`: without a
single-instance guard — a lock file in the user data directory plus a local socket forwarding the
URL to the running instance — the user gets a second window instead of a navigation.

## Testing With adb

```bash
PKG=com.example.app

# 1. the app half: bypasses the chooser, so it proves the parser and the routing only
adb shell am start -W -a android.intent.action.VIEW -d "https://example.com/orders/42" $PKG

# 2. the custom scheme reaching the same route
adb shell am start -W -a android.intent.action.VIEW -d "myapp://app/orders/42" $PKG

# 3. the system half: no package, so Android decides. A chooser here means unverified
adb shell am start -W -a android.intent.action.VIEW -d "https://example.com/orders/42"

# 4. verification state, one line per declared host
adb shell pm get-app-links $PKG

# 5. cold start for real — kill first, or you are testing the warm path
adb shell am force-stop $PKG
adb shell am start -W -a android.intent.action.VIEW -d "https://example.com/orders/42" $PKG
```

1. **`-W` waits and prints the result**; without it a failed start is silent and reads as a parser
   bug. `&` ends the command in the device shell, so escape it as `\&` inside a query.
2. **Commands 1 and 3 fail differently, and that is the point.** An unverified filter passes 1 and
   fails 3 — exactly the report "it works on my device and opens the browser on theirs".
3. **Test the gate by hand:** sign out, run command 5, land on sign-in, sign in, and confirm the app
   then lands on the order — once. Signing in twice must not navigate twice.
4. **Desktop equivalents:** `open "myapp://app/orders/42"` on macOS, `xdg-open` on Linux,
   `Start-Process "myapp://app/orders/42"` in PowerShell.
5. **None of this is a regression test.** It needs a device, a network and a file someone else
   deploys. The regression tests are `The Parser Test` and the gate's; these commands belong on the
   release checklist (`spine-toolkit:ops-checklist`).
