---
name: di-hilt
description: "Use when the DI is Hilt (or plain Dagger) on Android — components and scopes, @Binds vs @Provides, @HiltViewModel and assisted injection, multibindings, entry points, KSP setup, and testing with @HiltAndroidTest and @TestInstallIn. Also when deciding Hilt vs Dagger vs Koin on Android."
---

# Hilt

Hilt is Dagger with the component hierarchy already written: you declare bindings, it generates the
components and attaches them to the Android lifecycles. This skill covers the parts a project has to
decide for itself — which component a binding is installed in, `@Binds` or `@Provides`, how a
ViewModel gets a runtime argument, and what a test replaces. Where the graph is assembled at all is
`di-composition-root`; on Android with Hilt the answer is `@HiltAndroidApp`, and that annotation is
the whole root.

> **Related skills:**
> - `di-composition-root` — where the root lives, what may run in it, and the three scopes Hilt's components implement
> - `di-koin` — the alternative, and the only option once the module has to compile for KMP
> - `arch-mvvm` — ViewModel design, `UiState` and `SavedStateHandle` use; this skill only covers how one is constructed
> - `nav-compose` — what `hiltViewModel(parentEntry)` is actually scoping to on a nested graph
> - `compose-state` — where the ViewModel a Hilt factory built sits among the other places state can live
> - `pkg-gradle-modules` — which modules get the Hilt plugin, and why a `:domain` module must not
> - `architecture-choice` — the decision that put Hilt in `## Stack` in the first place

## When to Use

- An Android project has Hilt in its build (or `## Stack` says `- DI: Hilt`) and a new binding,
  scope, ViewModel or test seam is being added
- User asks "`@Binds` or `@Provides`", "which component does this go in", "how do I pass an id into a
  ViewModel", "how do I fake the network layer in an instrumentation test", "why does Hilt say it
  cannot find a binding", "kapt or KSP"
- A non-Hilt class — a `ContentProvider`, a third-party callback, a `BroadcastReceiver` registered in
  the manifest — needs something from the graph
- Review finds `@Inject lateinit var` where the constructor was available, a `@Singleton` holding
  per-user state, or a module installed in `SingletonComponent` that only one screen uses
- The project is on Android only and someone is proposing Koin, or a shared JVM module needs DI and
  Hilt does not reach it

Not for the assembly decision itself (`di-composition-root`) and not for ViewModel design
(`arch-mvvm`) — this skill starts once Hilt is the answer.

## When To Load The Reference

`references/detailed-guide.md` carries one complete Hilt setup — build files through tests — plus the
plain-Dagger fallback. Each section stands alone; load the section, not the file:
`rg -n "^## " skills/di-hilt/references/detailed-guide.md`.

| Need | Reference section |
|---|---|
| Plugins, KSP, the artifacts and the version catalog entries | `Gradle and KSP Setup` |
| `@HiltAndroidApp`, and which classes may hold an `@Inject` field | `Application and Android Entry Points` |
| A module with both `@Binds` and `@Provides`, and a qualifier | `Modules` |
| A `@HiltViewModel` taking `SavedStateHandle`, collected in Compose | `ViewModels` |
| A ViewModel that needs a value known only at call time | `Assisted Injection` |
| A plugin or interceptor list contributed by several modules | `Multibindings` |
| Injecting into a `ContentProvider` or a third-party callback | `Entry Points for Non-Hilt Classes` |
| Replacing a module in tests, `@BindValue`, the custom test runner | `Testing` |
| A non-Android JVM module, or full control over the components | `Plain Dagger` |

## Hilt vs Dagger vs Koin

| | Hilt | Dagger | Koin |
|---|---|---|---|
| Targets | Android only | any JVM (Android included) | JVM, Android, KMP — including iOS and native |
| Resolution | compile time | compile time | runtime |
| Components | generated, tied to the Android lifecycles | you write every `@Component` and `@Subcomponent` | none — a container of definitions |
| Codegen | KSP (or kapt) | KSP (or kapt) | none; Koin Annotations adds an optional KSP layer |
| A missing binding | a build error naming the type and the component | a build error | a runtime failure, unless `verify()`/`checkModules()` runs in tests |
| Build cost | annotation processing on every module with a module or an entry point | the same | zero |
| Take it when | the app is Android-only and stays that way | a non-Android JVM module needs DI, or the generated component hierarchy is genuinely in the way | anything must compile for KMP, Compose Desktop or Ktor, or the graph is small enough that codegen is not worth its build time |

Hilt on Android-only, Koin on KMP or Desktop, never both in one build — the same row
`architecture-choice` lands on. Hilt *is* Dagger underneath, so the two are not a mix: a Hilt app
that needs a plain Dagger component in a non-Android module is one project using both APIs of one
library, which is fine and is the `Plain Dagger` reference section.

## Components and Scopes

Hilt generates a fixed component hierarchy. Installing a binding in a component decides which classes
can see it; adding the matching scope annotation decides how long the instance lives.

| Component | Scope annotation | Created / destroyed with | Holds |
|---|---|---|---|
| `SingletonComponent` | `@Singleton` | `Application` | the HTTP client, the database, `DataStore`, analytics, app-wide caches |
| `ActivityRetainedComponent` | `@ActivityRetainedScoped` | `Activity` creation → final destruction (survives rotation) | state shared by the ViewModels of one Activity |
| `ViewModelComponent` | `@ViewModelScoped` | one `ViewModel` | a helper one ViewModel owns and nothing else may share |
| `ActivityComponent` | `@ActivityScoped` | `Activity`, per instance (dies on rotation) | anything needing the `Activity` itself — a permission launcher, a navigator |
| `FragmentComponent` | `@FragmentScoped` | `Fragment` | Fragment-lifetime helpers, on a Views-based screen |
| `ViewComponent` | `@ViewScoped` | `View`; `@WithFragmentBindings` selects `ViewWithFragmentComponent` instead, which also sees the host Fragment's bindings | custom-view collaborators; rare |
| `ServiceComponent` | `@ServiceScoped` | `Service` | a foreground service's collaborators |

Two rules make this table usable:

1. **An unscoped binding is not a mistake.** Without a scope annotation Hilt creates a new instance
   per injection point. That is the correct default for anything cheap and stateless — a mapper, a
   use case, a validator. Scope is for things that are expensive or that must be shared.
2. **A binding may only depend on its own component or a wider one.** `@Singleton` code cannot see
   `@ActivityScoped` code, because the Activity outlives nothing and the singleton outlives it. Hilt
   fails that at build time, and the fix is never to widen the scope of the short-lived thing — it is
   to pass the short-lived value in as a parameter.

## Modules

A module tells Hilt how to build a type it cannot construct itself. Two forms, and the choice is
mechanical:

- **`@Binds`** — an `abstract fun` mapping an interface to an implementation Hilt already knows how to
  construct (its constructor is `@Inject`). No body, no generated factory method, nothing to run at
  runtime. This is the common case in a layered app: every repository, every gateway.
- **`@Provides`** — a `fun` with a body, for a type you do not own or cannot annotate: an `OkHttpClient`
  from a builder, a Room database, a `Json` instance, a `CoroutineDispatcher`.

That splits the file kinds: a module holding only `@Provides` is an `object` (no instance needed); a
module holding `@Binds` is an `abstract class` or an `interface`. Mixing both in one type requires a
`companion object` for the `@Provides` half, which is legal and slightly ugly — two modules read
better.

```kotlin
@Module
@InstallIn(SingletonComponent::class)
interface RepositoryModule {
    @Binds fun bindOrderRepository(impl: OrderRepositoryImpl): OrderRepository
}

@Module
@InstallIn(SingletonComponent::class)
object DispatcherModule {
    @Provides @IoDispatcher
    fun provideIo(): CoroutineDispatcher = Dispatchers.IO
}
```

When two bindings have the same type — two `String`s, two `CoroutineDispatcher`s, a real and a mock
`OrderRepository` — they are told apart by a **qualifier**: your own annotation marked `@Qualifier`,
applied at both the provision and the injection point. `@Named("io")` works and reads worse; a typed
qualifier is checked by the compiler.

Install a module in the narrowest component that can see everything it needs. A module every screen
uses belongs in `SingletonComponent`; a module one Activity uses belongs in `ActivityComponent`,
where it cannot accidentally become the app's third analytics client.

## ViewModels

`@HiltViewModel` puts a ViewModel in the graph; `hiltViewModel()` in Compose retrieves it, scoped to
the nearest `ViewModelStoreOwner` — which on a Navigation Compose graph is the back stack entry, not
the Activity (`nav-compose`).

```kotlin
@HiltViewModel
class OrderDetailViewModel @Inject constructor(
    private val orders: OrderRepository,
    savedStateHandle: SavedStateHandle,
) : ViewModel() {
    private val route = savedStateHandle.toRoute<OrderDetail>()
    // ... arch-mvvm owns everything below this line
}
```

`SavedStateHandle` is injectable in any `@HiltViewModel` with no declaration of your own, and it is
how a route argument reaches the ViewModel — which is why most screens need nothing else.

**Assisted injection is for the value the graph cannot know**: something computed at the call site, a
value from a callback, an id that is not a route argument. Mark it `@Assisted`, add an
`@AssistedFactory` interface, and pass the factory call to `hiltViewModel`:

```kotlin
@HiltViewModel(assistedFactory = OrderViewModel.Factory::class)
class OrderViewModel @AssistedInject constructor(
    private val orders: OrderRepository,
    @Assisted private val orderId: OrderId,
) : ViewModel() {
    @AssistedFactory interface Factory { fun create(orderId: OrderId): OrderViewModel }
}

// Compose call site, Hilt 2.49+ with hilt-navigation-compose 1.2.0+
val vm = hiltViewModel<OrderViewModel, OrderViewModel.Factory> { it.create(orderId) }
```

If the value **is** a route argument, use `SavedStateHandle` instead — assisted injection there buys
nothing and loses process-death survival.

## Multibindings

When several modules must contribute to one collection — analytics sinks, deep-link handlers,
startup tasks, interceptors — each contributes its own element and nobody owns the list:

- `@IntoSet` on a `@Binds`/`@Provides` adds one element to a `Set<T>`; `@ElementsIntoSet` adds several.
- `@IntoMap` plus a key annotation (`@StringKey`, `@ClassKey`, or your own `@MapKey`) builds a `Map<K, T>`.
- `@Multibinds` on an `abstract fun` declares a set or map that may legitimately be **empty** — without
  it, a collection nobody contributes to is a missing binding.

The trap is the injection site. Kotlin generates Java wildcards for generic parameters, so the
requested type stops matching the bound one:

```kotlin
class Analytics @Inject constructor(
    private val sinks: Set<@JvmSuppressWildcards AnalyticsSink>,
)
```

Without `@JvmSuppressWildcards` the constructor asks for `Set<? extends AnalyticsSink>` and Hilt
reports a missing binding for a type that is visibly right there. Every multibound collection needs
it; nothing else does.

## Entry Points

Hilt injects into classes it knows: `@AndroidEntryPoint` on an Activity, Fragment, View, Service or
`BroadcastReceiver`. Everything else — a `ContentProvider` (created before `Application.onCreate`
finishes), a manifest-registered receiver you do not control, a third-party callback, a JobService
from another library — reaches the graph through an `@EntryPoint` interface:

```kotlin
@EntryPoint
@InstallIn(SingletonComponent::class)
interface OrdersEntryPoint {
    fun orderRepository(): OrderRepository
}

// Inside the non-Hilt class:
val orders = EntryPointAccessors.fromApplication<OrdersEntryPoint>(context).orderRepository()
```

`EntryPointAccessors` has one accessor per component (`fromApplication`, `fromActivity`,
`fromFragment`, `fromView`), and each one is a **service locator call** — which is exactly why the
mechanism is a named escape hatch and not a convenience. Declare the narrowest interface the caller
needs, use it at the framework boundary only, and pass the results down as constructor parameters
from there.

## KSP Setup

Hilt supports KSP since 2.48, and KSP is the only sensible choice now: kapt generates Java stubs for
every source file in the module and is several times slower.

```kotlin
plugins {
    id("com.google.devtools.ksp")
    id("com.google.dagger.hilt.android")
}

dependencies {
    implementation("com.google.dagger:hilt-android:<version>")
    ksp("com.google.dagger:hilt-android-compiler:<version>")
    implementation("androidx.hilt:hilt-navigation-compose:<version>")   // hiltViewModel()
}

hilt { enableAggregatingTask = true }
```

Four things that decide build time and correctness:

1. **The Gradle plugin is required, not optional.** `com.google.dagger.hilt.android` runs the
   bytecode transform that makes `@AndroidEntryPoint` work; the annotation processor alone is not
   enough.
2. **`enableAggregatingTask = true`** makes the aggregating step incremental, so a change in one
   module stops reprocessing the app's whole classpath. It is the default in recent versions and
   worth asserting anyway.
3. **`ksp` in every module that declares a module, an entry point or an `@Inject` constructor** — the
   plugin does not propagate across module boundaries. A `:domain` module should declare none of
   those and therefore needs neither (`pkg-gradle-modules`).
4. **`androidx.hilt` artifacts are versioned separately** from `com.google.dagger` ones:
   `hilt-navigation-compose` for `hiltViewModel()`, `hilt-work` plus `androidx.hilt:hilt-compiler`
   for `@HiltWorker`.

## Testing

Instrumentation and Robolectric tests build the real graph and replace pieces of it.

| Need | Mechanism |
|---|---|
| Run a test against the Hilt graph | `@HiltAndroidTest`, a `HiltAndroidRule` at order 0, `hiltRule.inject()` in `@Before` |
| Replace a module for the whole test source set | a test module annotated `@TestInstallIn(components = [SingletonComponent::class], replaces = [NetworkModule::class])` |
| Replace a module for one test class | `@UninstallModules(NetworkModule::class)` plus local `@BindValue` fields |
| Substitute a single binding | `@BindValue val repo: OrderRepository = FakeOrderRepository()` — a field in the test, bound into the graph |
| The test `Application` | `HiltTestApplication`, installed by a `CustomTestRunner : AndroidJUnitRunner` that overrides `newApplication`, named in `testInstrumentationRunner` |
| The same on the JVM | Robolectric plus `@Config(application = HiltTestApplication::class)` |

`@TestInstallIn` is the one to reach for first: it is declared once, applies to every test, and keeps
individual test classes free of DI plumbing. `@UninstallModules` is per class and forces a separate
component build for that class, so it is slower and worth keeping for genuine one-offs.

Unit tests need none of this. A `@HiltViewModel` is an ordinary class with an ordinary constructor —
construct it with fakes and skip Hilt entirely. If a unit test needs Hilt, the class under test is
reaching for the graph instead of taking parameters.

## Common Mistakes

1. **`@Inject lateinit var` where the constructor was available.** Field injection exists for classes
   the framework constructs — Activities, Fragments, Services. Everywhere else it hides the
   dependency from the signature, makes the object legal to construct half-initialized, and forces
   the unit test to go through Hilt to build it. Constructor injection is the default; field
   injection is the exception with a reason.
2. **Scope mismatch, then widening to fix it.** A `@Singleton` that needs an `@ActivityScoped`
   collaborator is a build error, and promoting the Activity-scoped thing to `@Singleton` makes it
   compile and leak the Activity. The dependency is backwards: pass the Activity-lifetime value into
   the call, or move the logic to the narrower scope.
3. **`@Singleton` on stateful per-user services.** A cart, a session cache, a "current profile"
   holder marked `@Singleton` outlives the logout. The next user sees the previous one's data, and
   the bug only reproduces on a device where someone actually switched accounts. Per-user state
   belongs in a narrower scope, or in an app-scoped holder that is explicitly cleared
   (`di-composition-root`).
4. **Everything in `SingletonComponent`.** It always compiles, so it becomes the default, and the
   component that should have documented lifetime documents nothing. Install in the narrowest
   component that can see what it needs.
5. **A multibound collection without `@JvmSuppressWildcards`.** Hilt reports a missing binding for
   `Set<? extends T>` while the bindings are visibly present. Add the annotation at the injection
   site; there is no other fix.
6. **Hilt annotations in the domain module.** `@Inject` on a use case puts Dagger on `:domain`'s
   classpath and undoes the reason the module exists. The `@Binds` that names it lives in `:app`
   (`arch-clean`).
7. **`EntryPointAccessors` used as a general accessor.** It works from anywhere with a `Context`,
   which is why it spreads. Every call is a service locator; keep them at framework boundaries that
   genuinely cannot be constructed, and pass dependencies down from there.
8. **Still on kapt.** Hilt has supported KSP since 2.48, and kapt costs a stub-generation pass over
   every source file in every module that uses it. Migrating is a plugin swap and a `kapt(...)` →
   `ksp(...)` rename.
