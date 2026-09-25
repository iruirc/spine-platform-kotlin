---
name: di-composition-root
description: "Use when designing where a Kotlin app's object graph is assembled — Application class, main(), Spring context, Ktor module — what belongs there, sync vs async bootstrap, scopes (app / screen / request), the manual-graph option, which container each target takes, and how Hilt, Koin, Dagger and Spring each fill the role. DI-framework agnostic."
---

# Composition Root

The one place in a Kotlin process where concrete types are named and wired together — one per
process entry point, never one per feature. Which framework does the wiring is `di-hilt`, `di-koin`
or `di-spring`; this skill fixes **where** that wiring runs, what may run there, what the three
scope names mean before a framework renames them, and when a hand-written graph is still the right
answer.

> **Related skills:**
> - `di-hilt` — the Android answer: `@HiltAndroidApp` as the root, its components, scopes and test seams
> - `di-koin` — the same role filled by `startKoin`/`initKoin` on KMP, Compose Desktop, Ktor and Android
> - `di-spring` — the root a server does not write: the `ApplicationContext`, `@Configuration` and bean scopes
> - `arch-hexagonal` — why `:app` is the only module allowed to assemble, and the core carries no annotation
> - `arch-clean` — the same rule per layer: `:domain` never sees a container or an `@Inject`
> - `arch-mvvm` — what a ViewModel receives through its constructor, and why it resolves nothing itself
> - `pkg-gradle-modules` — which module the root lives in once the build is split, and what it may depend on
> - `pkg-kmp-source-sets` — why a KMP root is one `commonMain` function plus one call per platform entry
> - `architecture-choice` — DI is a decision parallel to the architecture; that skill picks the framework, this one places it

## When to Use

- A project is about to construct its first service and nobody has said where
- User asks "where do I call `startKoin`", "do I need Hilt for this", "can I just build the graph by
  hand", "where does the database get opened", "why is my app blank for two seconds on launch"
- A second entry point appears — an instrumentation test, a widget, a worker, a Spring test slice —
  and the graph has to be built again
- Review finds a service constructed inside a ViewModel, a global `object` holding the graph, a
  `runBlocking` in `Application.onCreate`, or a `var` on the graph
- The manual graph has crossed the size where every new dependency is a three-file edit

Not for the mechanics of one framework — `di-hilt`, `di-koin`, `di-spring` own those. Which
framework a target takes is decided here, and `architecture-choice` writes the answer as the
`- DI:` line.

## Why a Composition Root

Without one, `HttpClient(...)`, `Database.open(...)` and `OrderRepositoryImpl(...)` appear wherever
somebody needed them. That buys four problems at once:

- **Hidden dependencies.** A constructor takes nothing and the class still talks to the network. The
  signature stops describing the class.
- **Coupling to implementations.** A ViewModel that calls `OrderRepositoryImpl(...)` depends on the
  data module forever, and the interface it was supposed to hold buys nothing.
- **Duplicate expensive objects.** Two `HttpClient`s means two connection pools; two `Database`s on
  one file means a lock contest.
- **Untestable seams.** Replacing one implementation means editing the call site, so the fake has to
  be a compile-time trick rather than a constructor argument.

The root inverts all four: **only the root** knows every concrete type. Everything below it takes
what it needs through its constructor and could not name an implementation if it wanted to.

## Where It Lives

| Target | The root runs in | What builds the graph there |
|---|---|---|
| Android | the `Application` class — `onCreate`, or the class itself | Hilt: `@HiltAndroidApp` — the annotation **is** the root, the graph is generated. Koin: `startKoin { androidContext(this@App); modules(appModule) }`. Manual: an `AppGraph` field on the `Application` |
| Compose Desktop | `main()`, before `application { }` opens the first window | `startKoin { modules(appModule) }`, or `val graph = AppGraph(config)` passed down the composable tree |
| Spring | nowhere you write — the `ApplicationContext` **is** the root | `@SpringBootApplication` on `main`, `@Configuration` classes and the component scan; `di-spring` |
| Ktor | `Application.module()` | `install(Koin) { modules(appModule) }`, or `val graph = AppGraph(environment.config)` at the top of `module()` |
| CLI | `main()` | build the graph, then run the command: a Clikt `CliktCommand` takes its dependencies through its constructor, never from a global |
| KMP | a `commonMain` `fun initKoin(appDeclaration: KoinAppDeclaration = {})` | each platform entry calls it — Android `Application.onCreate`, iOS `MainViewController` (or `KoinKt.doInitKoin` called from the iOS app entry), desktop `main()` |

```kotlin
// commonMain — the whole shared root, and the only place modules are listed.
fun initKoin(appDeclaration: KoinAppDeclaration = {}): KoinApplication =
    startKoin {
        appDeclaration()
        modules(coreModule, dataModule, platformModule())
    }

// androidMain
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        initKoin { androidContext(this@App) }
    }
}
```

The `appDeclaration` parameter is the reason this shape is worth copying: it is the only seam each
platform needs to add its own context, and it costs nothing when a platform has none.

## What It Must and Must Not Do

The root has exactly two jobs:

1. **Build the graph** — construct the concrete types and hand each one its dependencies.
2. **Wire configuration** — read the environment, the build type, the properties file once, and pass
   the values in as typed things (a `Duration`, a `BaseUrl`, a `RetryPolicy`), not as a `Config`
   object every service then parses for itself.

There is no third job.

| Anti-pattern in the root | Why it is wrong | Where it belongs |
|---|---|---|
| Business logic — a discount rule, a mapping, a validation | The root grows one branch per feature and becomes the file everyone edits | The service or use case that owns the rule |
| Reachable from feature code — `AppGraph.instance.orders` inside a repository | That is a service locator: the dependency vanishes from the constructor, and the domain now imports the root | Constructor parameters, all the way down |
| Mutable state — `var currentUser` on the graph | Unsynchronized shared state, and the user's lifetime silently became the process's | A session-scoped holder (see Scopes) |
| I/O — a config fetch, a migration, a cache warm-up | Blocks the first frame or the first request, and the failure has nowhere to be reported | `suspend fun bootstrap()` (see Bootstrap) |
| Navigation, or building screens | Ties the root to the UI framework and to the current screen list | `nav-compose`, or a factory the root hands out |
| Amending the graph after start | Resolve order becomes a race between the amendment and the first screen | Declare it all before anything resolves |

## Container vs Manual Graph

The smallest honest root is a class with `val`s:

<!-- compile: jvm -->
```kotlin
class AppGraph(private val config: Config) {
    val http: HttpClient by lazy { newHttpClient(config.baseUrl, config.timeouts) }
    private val db: Database by lazy { Database.open(config.dbPath) }

    val orders: OrderRepository by lazy { OrderRepositoryImpl(http, db) }
    val placeOrder: PlaceOrder by lazy { PlaceOrder(orders, clock) }

    private val clock: Clock = Clock.System
}
```

`by lazy` is doing real work here: it makes declaration order irrelevant, so the graph can be written
in the order a reader wants rather than the order the compiler needs, and nothing expensive is built
until something asks. Every member is a `val`. A `var` on a graph is shared mutable state with extra
steps.

A manual graph is the right answer far longer than DI-framework documentation suggests. It stops
fitting on any one of these:

1. **Around ten services and climbing.** Below that the file reads as documentation of the app; above
   it, it reads as a chore, and every new dependency is an edit in three places.
2. **A lifetime that is not "the process".** The moment something must live per screen, per request
   or per user session, `by lazy` has no way to say so and you start hand-rolling scopes — which is
   the framework's actual job (see Scopes).
3. **Test overrides across many tests.** One fake is a constructor argument. A fake the whole suite
   shares, or twenty tests each swapping their own, want the container's test seams — Hilt's
   (`di-hilt` → "Testing") or a Koin override module — not twenty subclasses of `AppGraph`.
4. **A multi-module graph.** When `:feature:orders` must contribute its own bindings without `:app`
   importing its internals, you want per-module modules — Hilt's `@InstallIn`, Koin's `module { }` —
   not one class that imports every module in the build (`pkg-gradle-modules`).

## Choosing the Container

One row per target. A graph that has reached none of the four limits under Container vs Manual Graph
stays manual on every target that lets you choose.

| Target | Container | Because |
|---|---|---|
| Android | Hilt | a compile-time graph with components generated for the Android lifecycles |
| Compose Desktop, KMP | Koin | no code generation, and one graph serves `commonMain` and every platform entry |
| Ktor, http4k | Koin | the framework brings no container; `koin-ktor` installs into `Application.module()` |
| Spring Boot | Spring's own | the `ApplicationContext` is the root already; Micronaut and Quarkus bring their own the same way |
| CLI | manual | a handful of constructor calls at the top of `main()` (see When You Do Not Need One) |

1. **Never two containers in one build.** Half the graph is invisible to the other half, and neither
   verification test covers the seam.
2. **Plain Dagger is not a row.** It is Hilt's own library with the components written by hand, for
   a JVM module or a tool inside a Hilt build that needs a graph of its own (`di-hilt`).
3. **A build already on a container keeps it** until a row's reason bites — a Hilt app gaining a
   `commonMain` module is the usual one, and it is a migration, not a second container beside the
   first.

## Scopes

Three lifetimes cover almost everything. Anything else is one of these three under a local name.

| Scope | Lives for | Hilt | Koin | Spring | Ktor + Koin |
|---|---|---|---|---|---|
| **app** | the whole process | `@Singleton` in `SingletonComponent` | `single { }` | `singleton` — the default | `single { }` |
| **ViewModel or screen** | one screen, across configuration changes, until the back stack entry goes | `@ViewModelScoped` in `ViewModelComponent` | `viewModel { }` | n.a. — a server has no screen | n.a. |
| **request or session** | one HTTP call, or one signed-in user | n.a. — Android has no request; a user session is a scope you build, not one Hilt names | `scope<UserSession> { scoped { } }` | `@RequestScope`, `@SessionScope` | `requestScope { scoped { } }`, which `koin-ktor` opens and closes per call as `call.scope` |

The `n.a.` cells are honest, not gaps. Android's per-user state is the one that catches people: there
is no built-in scope whose lifetime is "until logout", so either the holder is app-scoped and
explicitly cleared on logout, or the graph gets a user scope you open and close yourself.

Everything expensive and stateless — the HTTP client, the database, the serializer, the analytics
sink — is app scope. Everything holding a user's in-progress work is narrower than app scope. Picking
app scope because it was the shortest annotation is how a logged-out user keeps seeing the previous
user's cache.

## Bootstrap: Sync vs Async

**Sync is the normal case, and it must stay cheap.** Constructing the graph is constructor calls and
`by lazy` bodies; on Android it happens before the first frame, on a server before the first request.
Never do I/O there. `runBlocking { remoteConfig.fetch() }` in `Application.onCreate` is a blank screen
on a slow network and a startup ANR on a bad one — and the user reports it as a crash.

**Async work gets its own function.** A remote config fetch, opening or migrating a database, warming
a cache, validating a licence — all of it goes into one suspending entry point the root exposes:

```kotlin
class AppGraph(config: Config) {
    // ... vals as above

    suspend fun bootstrap() {
        db.migrateIfNeeded()          // persistence-migrations
        remoteConfig.refresh()        // failures land here, where there is a state to show
    }
}
```

Where it is run from, per target:

| Target | Runs `bootstrap()` from | What the user sees while it runs |
|---|---|---|
| Android, Compose Desktop | the first screen's ViewModel, or a splash destination | a loading state, then an error state on failure (`compose-state`) |
| Spring | an `ApplicationRunner` bean, or `@EventListener(ApplicationReadyEvent::class)` | nothing — the context fails to start, which is the correct outcome |
| Ktor | `monitor.subscribe(ApplicationStarted) { ... }` inside `module()` | nothing — readiness stays false until it completes |

The rule underneath all three rows: **a bootstrap failure must have somewhere to be reported.** In
the root there is no UI and no request, so the only thing it can do is crash. One step later there is
a loading state, a health probe or a log line with a retry.

## Multiple Composition Roots

More than one root is normal. The unit is the **process entry**, never the feature.

| Entry | Its root |
|---|---|
| The app process | the `Application` / `main()` above |
| An instrumentation test process | `HiltTestApplication` behind a custom runner, or a test `initKoin` loading fake modules (`di-hilt`) |
| A component in its own `android:process` — a worker, a widget provider, a `ContentProvider` | the `Application` is created again there, so the root runs again; a `WorkManager` worker plugs into it with `@HiltWorker` rather than building a second graph |
| A Spring `@SpringBootTest` or a slice test | its own `ApplicationContext`, built from a subset of the `@Configuration` classes |

What is **not** a legitimate second root: a per-feature `OrdersGraph` that constructs its own
`HttpClient`. That is a second connection pool, a second cache and two places to change a timeout. A
feature contributes **bindings** to the one root; it does not own a root.

## Testing

The root is infrastructure, so it gets one test, not a suite: **build it once with fakes and assert it
resolves.** What that looks like per framework:

| Framework | The test |
|---|---|
| Hilt | a `@HiltAndroidTest` that injects and asserts, with `@TestInstallIn` replacing the network module for the whole test source set |
| Koin | the Koin Compiler Plugin's build-time check, or a `verify()` test — either walks every definition and fails on a missing one, with no app run (`di-koin` → "Testing") |
| Spring | `@SpringBootTest` loading the context **is** the assertion: it fails on a missing or ambiguous bean |
| Manual `AppGraph` | construct it with a test `Config` and touch every public `val` |

<!-- compile: jvm-test -->
```kotlin
@Test
fun appGraph_testConfig_resolvesEveryDependency() {
    val graph = AppGraph(Config.forTests(dbPath = ":memory:"))

    assertNotNull(graph.http)
    assertNotNull(graph.orders)
    assertNotNull(graph.placeOrder)
    assertSame(graph.orders, graph.orders)   // app scope really is one instance
}
```

Two things this catches that nothing else does: a `by lazy` cycle, which overflows the stack the
first time a `val` on it is touched — so the test has to touch every public `val`, or the cycle it
missed waits for the first user — and an app-scoped `val` that quietly became a `get()` and is now
handing out a new instance per call.

## When You Do Not Need One

- **A single-file script.** `main()` with four locals is already the root; naming it `AppGraph` adds a
  file and no information.
- **A library.** It has no process and no lifecycle, and its callers own the graph. Take dependencies
  as constructor parameters, ship no container, and let the application decide the lifetimes.
- **A CLI with three classes.** Constructing them by hand at the top of `main()` is the whole root.
  Reach for a framework when the command list, not the class count, starts growing.

In every other case the root pays for itself the first time an implementation has to change.

## Common Mistakes

1. **The graph reachable as a global** — `object AppGraph`, `GraphHolder.instance`, or
   `GlobalContext.get().get<OrderRepository>()` inside a repository. That is a service locator wearing
   a DI framework's name: the dependency disappears from the constructor, the domain gains an import
   it should never have, and every test that wants a fake has to reach the same global.
2. **I/O in the root** — `runBlocking { }` in `Application.onCreate`, a migration in `module()`, a
   licence check before the first window. Blocking startup has no error state to fail into; move it
   into `suspend fun bootstrap()` and give it a loading screen or a readiness probe.
3. **Mutable state on the graph** — `var currentUser`, `var authToken`. Every consumer now shares an
   unsynchronized field, and a per-user value has quietly taken the process's lifetime. Give it a
   scope, or an explicitly cleared holder.
4. **One root per feature** — `OrdersGraph`, `ProfileGraph`, each constructing its own client and
   cache. Features contribute bindings to the single root; they do not own roots.
5. **A container annotation in the domain** — `@Inject`, `@Singleton` or `@Component` on a use case.
   `@Component`, Spring's stereotype, puts Spring on the classpath of the module whose entire point was not needing one;
   `@Inject` and `@Singleton` are JSR-330 (`javax.inject`), not Dagger, but they still decide in the
   domain how and for how long a class is built, which is the root's job (`arch-clean`,
   `arch-hexagonal`).
6. **App scope by default** — `@Singleton` or `single { }` on everything, because it is the shortest
   thing to write. The first symptom is stale data surviving a logout; the second is a test that
   passes alone and fails in a suite.
7. **Two frameworks in one build** — Hilt for the app module and Koin for a shared one, so half the
   graph is invisible to the other half and neither verification test covers the seam. Pick one per
   build (see Choosing the Container).
8. **Configuration read where it is used** — services calling `BuildConfig`, `System.getenv` or
   `environment.config` for themselves. Every one of them is now untestable without the environment;
   read it once in the root and pass typed values down.
