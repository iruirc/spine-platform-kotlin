---
name: di-koin
description: "Use when the DI is Koin — on KMP, Compose Desktop, Ktor or Android. Covers modules and definitions (single, factory, viewModel, scope), constructor DSL, KMP setup with platform modules, Koin Annotations and the Koin Compiler Plugin, the Ktor plugin, verifying the graph in tests, and Koin vs Hilt on Android."
---

# Koin

Koin is a container of lambdas: a module lists how to build each type, the container resolves by type
at runtime, and there is no code generation between the declaration and the object. That lets one
graph compile for every Kotlin target with no processor in the build — Metro and kotlin-inject reach
KMP too, through a compiler plugin and KSP — and it moves the cost of a missing binding from the build
to the first resolve, which is why a Koin graph needs a check before its users are the check: the Koin
Compiler Plugin at build time, or a `verify()` test.
Where the graph is assembled at all is `di-composition-root`; this skill covers what goes into the
modules once Koin is the answer.

> **Related skills:**
> - `di-composition-root` — where `startKoin` is called from on each target, and what may run there
> - `di-hilt` — the Android alternative, and the comparison table this skill's last section agrees with
> - `di-spring` — the same role filled by a container you do not declare, on a Spring server
> - `arch-mvvm` — ViewModel design and `UiState`; this skill only covers how one is built and retrieved
> - `nav-multiplatform` — the back stack `koinViewModel` scopes to, and why no `Navigator` is bound here
> - `pkg-kmp-source-sets` — where `expect val platformModule` and its `actual`s live in the source-set tree
> - `architecture-choice` — the decision that put Koin in `## Stack` rather than Hilt or Spring

## When to Use

- A project has `org.koin` in its build (or `## Stack` says `- DI: Koin`) and a definition, scope,
  module or test seam is being added
- User asks "`single` or `factory`", "how do I get a dependency into a KMP `commonMain` class", "how
  do I pass an id into a ViewModel", "why does Koin say no definition found at runtime", "should I
  use Koin Annotations", "how do I fake the repository in a test"
- A second target appears — iOS, desktop, a Ktor service sharing the domain — and the Android-only
  modules have to move into `commonMain`
- Review finds `get()` called inside a repository, `GlobalContext.get()` in a library, `single { }`
  on a per-user cache, or a module list nothing verifies
- The Android app is Koin and someone is proposing Hilt, or the reverse

Not for where the root lives (`di-composition-root`), not for ViewModel design (`arch-mvvm`) — this
skill starts once Koin is the container.

## Definitions

A module is a list of definitions. Each one says how to build a type and how long the result lives.

| Definition | Lifetime | Use it for |
|---|---|---|
| `single { }` | one instance per Koin application, built on first resolve | the HTTP client, the database, the serializer, a repository — expensive or shared, and stateless |
| `single(createdAtStart = true) { }` | the same, built during `startKoin` | the rare thing that must exist before the first screen: a crash reporter, a log sink |
| `factory { }` | a new instance on every resolve | cheap stateless helpers, mappers, use cases — the correct default when in doubt |
| `viewModel { }` / `viewModelOf(::X)` | one per `ViewModelStore` owner, across configuration changes | ViewModels; `koin-android` on Android, `koin-core-viewmodel` plus `koin-compose-viewmodel` in `commonMain` |
| `scoped { }` inside `scope<T> { }` | one per open scope instance, gone when the scope closes | per-session, per-request or per-Activity collaborators (see Scopes) |

Four modifiers do the rest of the work:

- **`singleOf(::OrderRepositoryImpl)` / `factoryOf(::X)` / `viewModelOf(::X)`** — the constructor DSL.
  It reads the constructor's parameter types and resolves each one, with no reflection and no lambda
  to keep in step with the constructor. Prefer it; drop to `single { }` only when a parameter is not
  a graph type (a literal, a `String` from config) or when the body does more than construct.
- **`bind<Interface>()`** — a definition is registered under the type it returns. `singleOf(::OrderRepositoryImpl)`
  makes `OrderRepositoryImpl` resolvable and `OrderRepository` **not**. Add
  `singleOf(::OrderRepositoryImpl) { bind<OrderRepository>() }`, or write `single<OrderRepository> { OrderRepositoryImpl(get()) }`
  so the declared type is the interface. `binds(arrayOf(A::class, B::class))` for more than one.
- **`named("…")`** — a qualifier, for two definitions of the same type. Declared with
  `single(named("io")) { Dispatchers.IO }`, resolved with `get(named("io"))` or
  `by inject(named("io"))`. Both sides must agree on a string, which is exactly the weakness a
  compile-time container does not have; keep the names in one `object` of constants.
- **`parametersOf(...)`** — a value known only at the call site, handed in at resolve time:
  `get<OrderLoader> { parametersOf(orderId) }` against `factory { (id: OrderId) -> OrderLoader(id, get()) }`.
  It is for arguments, never for dependencies: anything the graph could have supplied should be a
  constructor parameter the container fills.

## Module Layout

**One module per feature or per layer, and one module that pulls them together.** The unit is
whatever a build module or a feature owns, so that adding a feature adds a file rather than editing
a shared one:

<!-- compile: android -->
```kotlin
// data/di/DataModule.kt
val dataModule = module {
    singleOf(::OrderRepositoryImpl) { bind<OrderRepository>() }
    singleOf(::StockRepositoryImpl) { bind<StockRepository>() }
}

// domain/di/DomainModule.kt
val domainModule = module {
    factoryOf(::PlaceOrder)
    factoryOf(::CancelOrder)
}

// app/di/AppModule.kt — composition, not declaration
val appModule = module {
    includes(dataModule, domainModule, networkModule)
}
```

`includes(...)` flattens the listed modules into this one and de-duplicates them, so a module may be
included from two places without a duplicate-definition error. That is what makes a feature module
safe to reference from both the app and its own instrumentation test.

On KMP the layout gains one seam. Shared modules live in `commonMain`; everything a platform must
supply — the SQLDelight driver, the Android `Context`, the platform HTTP engine — goes behind one
`expect` declaration:

```kotlin
// commonMain
expect val platformModule: Module

fun initKoin(appDeclaration: KoinAppDeclaration = {}) = startKoin {
    appDeclaration()
    modules(commonModule, platformModule)
}

// androidMain
actual val platformModule = module {
    single<SqlDriver> { AndroidSqliteDriver(AppDatabase.Schema, androidContext(), "orders.db") }
}

// iosMain
actual val platformModule = module {
    single<SqlDriver> { NativeSqliteDriver(AppDatabase.Schema, "orders.db") }
}
```

The `appDeclaration` parameter is the only seam a platform entry needs to add its own context —
`initKoin { androidContext(this@App) }` from `Application.onCreate`, a bare `initKoin()` from a
desktop `main()` or from the iOS app entry through the generated `KoinKt.doInitKoin`. Where each of
those entries lives is `di-composition-root`; the source-set placement is `pkg-kmp-source-sets`. A
`fun platformModule(): Module` reads the same and is the better form when the module needs an
argument.

### Koin Annotations and the Compiler Plugin

The Koin Compiler Plugin — a Kotlin compiler plugin, Gradle id `io.insert-koin.compiler.plugin` —
replaces the `koin-ksp-compiler` processor and its `KOIN_CONFIG_CHECK` option. It does two jobs:

- **It checks the graph at build time.** In a compilation that calls `startKoin` or `koinApplication`,
  or declares `@KoinApplication`, every module assembled there is validated together, the plain DSL
  included, and a missing definition fails the build (`[Koin][KOIN-D001] Missing dependency: …`).
  A module no entry point reaches is not checked; a test that calls `koinApplication { modules(…) }`
  is an entry point.
- **It processes `io.insert-koin:koin-annotations`**: `@Single`, `@Factory`, `@KoinViewModel` and
  `@Scope` on the classes themselves, gathered by an `@Module @ComponentScan` class. That pays on a
  large graph, where the modules had become a second copy of the constructor list and drifted from it.

It runs inside `compileKotlin` rather than as a KSP round, and it moves with the Kotlin compiler, so
its version has to support the project's Kotlin. Annotations are a decision for the graph as a whole,
not per feature; hand-written modules stay a fine answer, with or without the plugin.

## Scopes

`di-composition-root`'s scopes table owns the cross-framework rows — what app, screen and
request/session mean before any container renames them. This one is narrower: Koin has one scope
mechanism and Android has another, and the common mistake is to reach for the wrong one.

| Need | Reach for | Closed by |
|---|---|---|
| Something per screen, surviving rotation | `viewModel { }` / `viewModelOf(::X)` | Android's `ViewModelStore`, when the owner is finished — **not** a Koin scope |
| Something per signed-in user, per wizard, per open document | `scope<UserSession> { scoped { } }` | you, by calling `scope.close()` |
| Something per Activity or Fragment on a Views screen | `activityScope()` / `fragmentScope()` from `koin-android` | the lifecycle observer those helpers install |
| Something per HTTP request | a Ktor request scope (see below) | the plugin, when the call ends |
| Everything else | `single { }` or `factory { }` | the process |

A Koin scope is an object with a lifetime you open and close by hand:

```kotlin
val sessionModule = module {
    scope<UserSession> {
        scoped { CartHolder() }
        scoped<SyncQueue> { SyncQueueImpl(get(), get()) }
    }
}

class SessionManager(private val koin: Koin) {
    private var scope: Scope? = null

    fun signIn(user: User) { scope = koin.createScope<UserSession>(user.id.value) }
    fun signOut() { scope?.close(); scope = null }   // every scoped instance goes with it
}
```

`close()` is the whole point: it is the only construct in Koin that makes "until logout" a lifetime
the container understands, and it is what a `single` holding per-user state can never do. A class
that lives inside a scope can implement `KoinScopeComponent` to resolve from its own scope rather
than from the root, which keeps the scope from leaking into the call sites.

`viewModel { }` is not in this table by accident. It looks like a scope and is not one: the instance
is held by Android's `ViewModelStore`, keyed to the `ViewModelStoreOwner` that asked for it, and Koin
only supplies the factory. That is why a ViewModel survives rotation with no code from you, and why
resolving one outside a `ViewModelStoreOwner` has nothing to hold it.

## Compose

Two functions cover almost every call site, from `koin-androidx-compose` on Android and
`koin-compose` plus `koin-compose-viewmodel` on Compose Multiplatform:

<!-- compile: android -->
```kotlin
@Composable
fun OrdersScreen(
    viewModel: OrdersViewModel = koinViewModel(),
    onOrder: (OrderId) -> Unit,
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    OrdersContent(state, onEvent = viewModel::onEvent, onOrder = onOrder)
}

@Composable
fun OrderDetailScreen(orderId: OrderId) {
    val viewModel: OrderDetailViewModel = koinViewModel { parametersOf(orderId) }
    // ...
}
```

- **`koinViewModel()`** resolves a `viewModel { }` definition against the nearest
  `ViewModelStoreOwner`, which under Navigation Compose is the back stack entry. Pass
  `viewModelStoreOwner = parentEntry` to share one ViewModel across a nested graph, exactly as
  `nav-compose` describes for `hiltViewModel`.
- **`koinInject()`** resolves anything else — a formatter, an image loader, a clock — for a
  composable that genuinely needs it and has no ViewModel. It is a service locator call, so keep it
  at the screen's edge and pass the result down as a parameter.
- **Previews and desktop entry points need a container.** A desktop `main()` that calls `startKoin`
  before `application { }` needs nothing more: the composition finds the started container, and the
  `KoinContext { … }` wrapper Koin once asked for is deprecated. A tree that starts its own wraps
  itself in `KoinApplication(configuration = koinConfiguration { modules(appModule) }) { … }`; a
  preview uses `KoinApplicationPreview(application = { modules(previewModule) }) { … }`, which builds
  an isolated container and never touches the global one. Fake definitions in a preview keep it from
  needing a database.

## Ktor Plugin

`koin-ktor` installs the container into the `Application`, which makes `Application.module()` the
composition root a Ktor service otherwise lacks:

<!-- compile: ktor -->
```kotlin
import org.koin.ktor.plugin.scope
import org.koin.logger.slf4jLogger

fun Application.module() {
    install(Koin) {
        slf4jLogger()               // koin-logger-slf4j
        modules(appModule)
    }
    routing { orderRoutes() }
}

fun Route.orderRoutes() {
    val orders by inject<OrderService>()     // lazy: resolved on first access, then cached

    get("/orders/{id}") {
        val perRequest = call.scope.get<RequestContext>()
        call.respond(orders.byId(call.parameters.getOrFail("id"), perRequest.traceId))
    }
}
```

- **`by inject()` at the route level, not inside the handler.** `Route.inject<T>()` hands back a
  `lazy`: the delegate is created while the route is built and resolved on first access — inside the
  first request that reaches it. The resolve still happens once per process rather than once per
  request, but a missing binding surfaces on that first request, per this skill's opening rule.
- **`requestScope { scoped { … } }` declares per-request definitions**, and `call.scope` is the scope
  the plugin opens for the call and closes when it ends. That is where a trace id, a caller identity
  or a per-request `UnitOfWork` belongs — the row `di-composition-root` calls "request or session".
- **`slf4jLogger()` is worth installing.** Koin's default is `EmptyLogger`, which prints nothing at
  any level, so a failed resolve leaves only the exception. With the logger installed, the line
  naming the type nobody defined is most of the diagnosis.

## Testing

Runtime resolution means the graph is only as correct as the last thing that resolved it. **Something
must walk every definition before a user does**, and on a Koin project that check is not optional:
the Compiler Plugin at build time (see Koin Annotations and the Compiler Plugin), or one `verify()`
test.

| Need | Mechanism |
|---|---|
| Prove every definition can be built | `appModule.verify()` from `koin-test`, in a plain JVM unit test — it walks each definition's constructor and fails naming the type and the definition that wanted it, with nothing started. Its signature names the experimental `ParameterTypeInjection`, so the call warns until the test opts in to `@KoinExperimentalAPI` |
| Verify a type the graph does not declare — `SavedStateHandle`, a `Context` | `appModule.verify(extraTypes = listOf(SavedStateHandle::class))` |
| Resolve inside a test | implement `KoinTest`, then `by inject()`; start the container with `KoinTestRule.create { modules(appModule) }` (`koin-test-junit4`) or `KoinTestExtension.create { … }` (`koin-test-junit5`) |
| Replace one binding for one test | `declare<OrderRepository> { FakeOrderRepository() }` inside the test, or a small override module listed after the real one — later definitions win by default |
| A mock rather than a fake | `declareMock<OrderRepository>()`, with a `MockProviderRule` naming the mocking library |
| Tear down | `stopKoin()` after any test that started a container; the rule and the extension do it for you |

<!-- compile: android-test -->
```kotlin
import org.koin.core.annotation.KoinExperimentalAPI
import org.koin.test.verify.verify

@OptIn(KoinExperimentalAPI::class)
class AppModuleTest {
    @Test
    fun verify_appModule_buildsEveryDefinition() {
        appModule.verify(extraTypes = listOf(SavedStateHandle::class))
    }
}
```

`verify()` reaches only what a reflective constructor walk can see: `single { }` bodies that call
`get()` inside a conditional, or a definition built from a `parametersOf` value, are checked as far
as their signature goes and no further. That is still the highest-value test in a Koin project,
because it catches the failure Koin actually has — a `bind<>()` nobody wrote, a module nobody
included — before a screen does. `checkModules { }` was the earlier form of the same idea and is
deprecated; new code uses `verify()`, or the Compiler Plugin, which also sees the bodies `verify()`
cannot.

Everything below the root needs none of this. A ViewModel, a use case and a repository are ordinary
classes with ordinary constructors — construct them with fakes and never start a container. If a unit
test needs Koin to build the class under test, that class is resolving from the graph instead of
taking parameters, which is the first mistake below.

## Koin vs Hilt on Android

On Android both work, and the axis is not preference: **Hilt resolves at compile time and Koin at
runtime**, so a missing binding is a build error with Hilt and a first-resolve crash with Koin unless
the Compiler Plugin or a `verify()` test catches it; Hilt generates components wired to the Android lifecycles, while Koin gives
you `viewModel { }` for the one lifecycle Android actually owns and `scope<T>` for the rest; and Hilt
costs an annotation-processing round in every module that declares a binding, which Koin does not.
Which one a build takes: `di-composition-root` → "Choosing the Container". Hilt does not leave the
JVM+Android world, so an Android app that will share a `commonMain` graph pays for Hilt twice.

## Common Mistakes

1. **`get()` or `by inject()` inside business code.** A repository that calls `get<HttpClient>()`, a
   use case with `by inject()`, an `object` reaching `GlobalContext.get()` — every one is a service
   locator. The dependency leaves the constructor, so the signature stops describing the class, the
   domain gains a Koin import it was built to avoid (`arch-clean`), and a test that wants a fake must
   start a container to supply it. Resolution belongs at the framework boundary only: `koinInject()`
   in a composable, `by inject()` in a Ktor route, `by viewModel()` in an Activity. Below that line,
   constructor parameters all the way down.
2. **A library that calls `startKoin`.** A published module has no process, so starting the global
   container hijacks its consumer's — and an app that already called `startKoin` gets
   `KoinAppAlreadyStartedException`, while one that has not gets a graph it never declared. Reaching
   `GlobalContext` from library code is the same bug wearing a getter. A library either takes its
   dependencies as constructor parameters and ships a `module { }` for the app to include, or holds
   its own isolated container built with `koinApplication { }` and never touches the global one.
3. **`single { }` on per-user state.** A cart, a session cache, a "current profile" holder declared
   `single` lives as long as the process, so the next user after a logout sees the previous one's
   data, and the bug reproduces only where someone actually switched accounts. That lifetime has a
   construct: `scope<UserSession>` with a `close()` on sign-out.
4. **`singleOf(::Impl)` with no `bind<Interface>()`.** The definition registers `Impl` only, so every
   `get<Interface>()` fails at runtime with "no definition found" while the implementation is visibly
   declared two lines up. Either add the `bind<>()` or declare the definition with the interface as
   its type argument.
5. **A ViewModel resolved outside a `ViewModelStoreOwner`.** `koinViewModel()` in a preview, in a
   composable hosted by nothing, or `get<OrdersViewModel>()` from a plain `single` — there is no
   store to hold the instance, so it is either rebuilt on every recomposition or fails outright.
   `viewModel { }` definitions are retrieved only from a screen; anything a non-screen needs is a
   `single` or a `factory`.
6. **`parametersOf` for what is a dependency.** Passing a repository, a dispatcher or a clock in at
   the call site puts the call site back in charge of construction and moves the failure to whichever
   caller forgot an argument. `parametersOf` is for values the graph cannot know — an id, a
   user-entered string, a value from a callback.
7. **Nothing checks the graph.** Runtime resolution with neither the Compiler Plugin nor a `verify()`
   test exercising the modules means the first user to open the one screen nobody tested is the
   check. One JVM test, one line.
8. **`named("…")` strings written twice.** The qualifier is a string on both sides and nothing
   compares them, so a typo is a runtime "no definition found" for a type that plainly exists. Keep
   qualifiers as constants in one file, or give the two things distinct types and delete the
   qualifier.
