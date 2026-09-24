# di-hilt — detailed guide

## Contents

- The App It Wires
- Gradle and KSP Setup
- Application and Android Entry Points
- Modules
- ViewModels
- Assisted Injection
- Multibindings
- Entry Points for Non-Hilt Classes
- Testing
- Plain Dagger

## The App It Wires

The app it wires is an orders screen over an `OrderRepository` backed by an HTTP client and a Room
database. Its implementation carries an `@Inject` constructor, which is what lets every later section
write `@Binds` instead of `@Provides`:

```kotlin
class OrderRepositoryImpl @Inject constructor(
    private val api: OrdersApi,
    private val dao: OrderDao,
) : OrderRepository { /* ... */ }
```

## Gradle and KSP Setup

Versions in the catalog, aliases in the build files. The KSP version's Kotlin prefix must match the
project's Kotlin version — a mismatch fails the build with a version message, the good case.

```toml
# gradle/libs.versions.toml
[versions]
hilt = "2.56.2"
androidxHilt = "1.2.0"
ksp = "2.1.21-2.0.1"          # <kotlin>-<ksp>

[libraries]
hilt-android = { module = "com.google.dagger:hilt-android", version.ref = "hilt" }
hilt-compiler = { module = "com.google.dagger:hilt-android-compiler", version.ref = "hilt" }
hilt-navigation-compose = { module = "androidx.hilt:hilt-navigation-compose", version.ref = "androidxHilt" }
hilt-work = { module = "androidx.hilt:hilt-work", version.ref = "androidxHilt" }
androidx-hilt-compiler = { module = "androidx.hilt:hilt-compiler", version.ref = "androidxHilt" }
hilt-android-testing = { module = "com.google.dagger:hilt-android-testing", version.ref = "hilt" }

[plugins]
ksp = { id = "com.google.devtools.ksp", version.ref = "ksp" }
hilt = { id = "com.google.dagger.hilt.android", version.ref = "hilt" }
```

Both plugins are declared `apply false` at the root and applied per module:

```kotlin
// app/build.gradle.kts
plugins {
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}

dependencies {
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    implementation(libs.hilt.navigation.compose)

    // @HiltWorker needs both compilers: androidx generates the worker factory entry.
    implementation(libs.hilt.work)
    ksp(libs.androidx.hilt.compiler)

    androidTestImplementation(libs.hilt.android.testing)
    kspAndroidTest(libs.hilt.compiler)
    testImplementation(libs.hilt.android.testing)   // the Robolectric half of Testing
    kspTest(libs.hilt.compiler)
}

hilt { enableAggregatingTask = true }
```

Per-module rules for a split build:

| Module | Hilt plugin | `ksp(hilt-compiler)` | Why |
|---|---|---|---|
| `:app` | yes | yes | the `Application`, the Activities, the app-wide modules |
| `:feature:*` | yes | yes | `@AndroidEntryPoint` screens, `@HiltViewModel`s, its own modules |
| `:data` | no | yes | `@Module`s and `@Inject` constructors, but no entry point to transform |
| `:domain` | no | no | plain Kotlin: no annotation, no processor, no Dagger on the classpath |

The `:domain` row is worth defending in review: one `@Inject` on a use case puts the container on the
classpath of the module whose point was not having one.

## Application and Android Entry Points

The root is the annotation. There is nothing to call, and nothing to hold.

```kotlin
@HiltAndroidApp
class OrdersApp : Application(), Configuration.Provider {

    // Only needed for @HiltWorker: WorkManager builds workers through this factory.
    @Inject lateinit var workerFactory: HiltWorkerFactory

    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder().setWorkerFactory(workerFactory).build()
}
```

Declared in the manifest as `android:name=".OrdersApp"`. For the `WorkManager` case the manifest must
also remove `androidx.work.WorkManagerInitializer` from `androidx.startup.InitializationProvider`
(`tools:node="remove"`), or the default initializer wins and the factory above never runs.

`@AndroidEntryPoint` marks each framework class that may receive injections. It is required on an
Activity before any Fragment inside it can use it, and on a Fragment's host before the Fragment.

```kotlin
@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    @Inject lateinit var analytics: Analytics      // field injection: the framework constructs this

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { OrdersRoot() }
    }
}

@AndroidEntryPoint
class SyncService : Service() {
    @Inject lateinit var sync: OrderSync
}
```

Field injection is correct in exactly these classes, because the framework calls their constructors —
nowhere else. A `WorkManager` worker takes a constructor instead: `@HiltWorker` with
`@AssistedInject`, `@Assisted Context` and `@Assisted WorkerParameters`.

## Modules

Three modules split by kind rather than by feature — interface bindings, third-party constructions,
qualified values — all in `SingletonComponent`, because everything they build lives for the process.

```kotlin
@Module
@InstallIn(SingletonComponent::class)
interface RepositoryModule {

    @Binds fun bindOrderRepository(impl: OrderRepositoryImpl): OrderRepository
    @Binds fun bindAnalytics(impl: RemoteAnalytics): Analytics
}
```

`@Binds` is an abstract function with no body: Hilt already knows how to construct
`OrderRepositoryImpl`, so the binding is a rename in the generated component. `@Provides` is for a
type you cannot annotate — a builder result, a library singleton, a value:

```kotlin
@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {

    @Provides @Singleton
    fun provideJson(): Json = Json { ignoreUnknownKeys = true }

    @Provides @Singleton
    fun provideOkHttp(@ApplicationContext ctx: Context): OkHttpClient =
        OkHttpClient.Builder()
            .callTimeout(30.seconds.toJavaDuration())
            .cache(Cache(ctx.cacheDir.resolve("http"), 20L * 1024 * 1024))
            .build()

    @Provides @Singleton
    fun provideRetrofit(client: OkHttpClient, json: Json): Retrofit =
        Retrofit.Builder()
            .baseUrl(BuildConfig.API_BASE_URL)
            .client(client)
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
            .build()

    @Provides
    fun provideOrdersApi(retrofit: Retrofit): OrdersApi = retrofit.create()
}
```

`provideOrdersApi` is unscoped on purpose: a Retrofit proxy is cheap, and the expensive things it
closes over are already `@Singleton`. Scope what is expensive, not what is convenient.
`@ApplicationContext` and `@ActivityContext` are the two qualifiers Hilt ships, from
`dagger.hilt.android.qualifiers`; your own are annotations, and are how two bindings of one type
stop colliding:

```kotlin
@Qualifier @Retention(AnnotationRetention.BINARY) annotation class IoDispatcher

@Module
@InstallIn(SingletonComponent::class)
object DispatcherModule {
    @Provides @IoDispatcher fun io(): CoroutineDispatcher = Dispatchers.IO
}

class OrderRepositoryImpl @Inject constructor(
    private val api: OrdersApi,
    private val dao: OrderDao,
    @IoDispatcher private val io: CoroutineDispatcher,
) : OrderRepository
```

Injecting the dispatcher rather than naming `Dispatchers.IO` inline is what lets a unit test hand the
repository a `StandardTestDispatcher` (`concurrency-coroutines`). A module holding both kinds puts
the `@Provides` half in a `companion object` of the `interface` — legal, and slightly worse to read
than two modules. Prefer two.

## ViewModels

```kotlin
@HiltViewModel
class OrderDetailViewModel @Inject constructor(
    private val orders: OrderRepository,
    savedStateHandle: SavedStateHandle,
) : ViewModel() {

    private val route: OrderDetail = savedStateHandle.toRoute()

    val state: StateFlow<OrderUiState> = orders.observe(route.orderId)
        .map { OrderUiState.Loaded(it) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), OrderUiState.Loading)
}
```

`SavedStateHandle` needs no binding of its own — Hilt provides it in `ViewModelComponent`, populated
from the back stack entry's arguments, and it survives process death; `toRoute()` turns those
arguments back into the typed route object (`nav-compose`). At the call site:

```kotlin
@Composable
fun OrderDetailScreen(viewModel: OrderDetailViewModel = hiltViewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    OrderDetailContent(state, onRetry = viewModel::retry)
}
```

`hiltViewModel()` resolves against the nearest `ViewModelStoreOwner` — inside a `NavHost` that is the
back stack entry, so the ViewModel dies with the destination. To share one across a nested graph,
pass the parent entry: `hiltViewModel(navController.getBackStackEntry<Checkout>())` (`nav-compose`).

A `@Provides @ViewModelScoped` binding in a module `@InstallIn(ViewModelComponent::class)` is one
instance per ViewModel: right for a helper two collaborators of one ViewModel share, wrong for
anything another screen might also want.

## Assisted Injection

Use it when a constructor parameter is known only at the call site and is **not** a route argument —
a callback value, an object the graph has no way to build.

```kotlin
@HiltViewModel(assistedFactory = OrderEditViewModel.Factory::class)
class OrderEditViewModel @AssistedInject constructor(
    private val orders: OrderRepository,
    @Assisted private val draft: OrderDraft,
) : ViewModel() {

    @AssistedFactory
    interface Factory {
        fun create(draft: OrderDraft): OrderEditViewModel
    }
}
```

The Compose call site takes both type arguments and a creation callback — Hilt 2.49+ with
`androidx.hilt:hilt-navigation-compose` 1.2.0+:

```kotlin
@Composable
fun OrderEditScreen(draft: OrderDraft) {
    val viewModel = hiltViewModel<OrderEditViewModel, OrderEditViewModel.Factory>(
        creationCallback = { factory -> factory.create(draft) },
    )
    // ...
}
```

The same `@AssistedInject` + `@AssistedFactory` pair works outside ViewModels — it is what
`@HiltWorker` uses for its `Context` and `WorkerParameters`, and what any class needing a runtime
value plus graph dependencies should use. Inject the `Factory`, not the class.

If the assisted value is a route argument, delete all of this and read `SavedStateHandle`: it
survives process death and assisted injection does not.

## Multibindings

A set of analytics sinks, each contributed by the module that owns it, with nobody holding the list:

```kotlin
interface AnalyticsSink { fun track(event: AnalyticsEvent) }

@Module
@InstallIn(SingletonComponent::class)
interface AnalyticsModule {
    @Binds @IntoSet fun bindRemoteSink(impl: RemoteAnalyticsSink): AnalyticsSink
    @Binds @IntoSet fun bindLogSink(impl: LogcatAnalyticsSink): AnalyticsSink

    // Declares the set so a flavour contributing nothing still compiles.
    @Multibinds fun sinks(): Set<AnalyticsSink>
}
```

A build-variant module contributes its own `@Provides @IntoSet` and nothing else changes. The
consumer asks for the set — and this is the line that goes wrong:

```kotlin
@Singleton
class Analytics @Inject constructor(
    private val sinks: Set<@JvmSuppressWildcards AnalyticsSink>,
) { fun track(event: AnalyticsEvent) = sinks.forEach { it.track(event) } }
```

Without `@JvmSuppressWildcards`, Kotlin compiles the parameter to `Set<? extends AnalyticsSink>` and
Dagger reports a missing binding for a type that is visibly bound two files away. The annotation is
required on every multibound collection and on nothing else.

Maps work the same way, keyed by an annotation — the right shape for a registry dispatched by a value:

```kotlin
@Module
@InstallIn(SingletonComponent::class)
interface DeepLinkModule {
    @Binds @IntoMap @StringKey("orders") fun orders(i: OrdersHandler): DeepLinkHandler
    @Binds @IntoMap @StringKey("profile") fun profile(i: ProfileHandler): DeepLinkHandler
}

class DeepLinkRouter @Inject constructor(
    private val handlers: Map<String, @JvmSuppressWildcards DeepLinkHandler>,
)
```

`@ClassKey` keys by `Class<?>`, so its injection site is `Map<Class<*>, @JvmSuppressWildcards T>`; a
custom `@MapKey` keys by whatever an annotation member may be — an enum, a `String`, a `Class` or a
primitive, never a value class. Use `@ElementsIntoSet` when one provider returns several elements.

The rule that keeps multibindings honest: contribute from the module that **owns** the element — once
`:app` lists every handler, the multibinding is a hand-written list with extra annotations.

## Entry Points for Non-Hilt Classes

Three kinds of class cannot be `@AndroidEntryPoint`: a `ContentProvider` (created before
`Application.onCreate` completes), a class another library instantiates, and a class you do not own.
Each reaches the graph through a declared interface.

```kotlin
@EntryPoint
@InstallIn(SingletonComponent::class)
interface OrdersEntryPoint {
    fun orderRepository(): OrderRepository
    fun analytics(): Analytics
}

class OrdersContentProvider : ContentProvider() {
    private val orders: OrderRepository by lazy {
        EntryPointAccessors
            .fromApplication(requireNotNull(context), OrdersEntryPoint::class.java)
            .orderRepository()
    }

    override fun query(/* ... */): Cursor? = orders.cursorFor(uri)
}
```

`by lazy` matters: a `ContentProvider`'s `onCreate` runs before the `Application` finishes
initializing, so resolving eagerly there fails. `EntryPointAccessors` has one accessor per component,
each taking the matching object: `fromApplication(context, T::class.java)` for `SingletonComponent`,
`fromActivity`, `fromFragment` and `fromView` for theirs.

A manifest-registered `BroadcastReceiver` you do own should be `@AndroidEntryPoint` instead — the
entry point is only for the ones you do not. The last legitimate case is a third-party callback that
hands you a `Context`, where `EntryPointAccessors.fromApplication<OrdersEntryPoint>(ctx)` is the only
way in. Each of these calls is a service locator: keep the interface narrow, keep the call at the
boundary, and pass what it returns into ordinary constructors from there.

## Testing

The runner installs `HiltTestApplication`, which is what gives the test process a graph at all:

```kotlin
class CustomTestRunner : AndroidJUnitRunner() {
    override fun newApplication(cl: ClassLoader?, name: String?, context: Context?): Application =
        super.newApplication(cl, HiltTestApplication::class.java.name, context)
}

// app/build.gradle.kts
android { defaultConfig { testInstrumentationRunner = "com.example.orders.CustomTestRunner" } }
```

`@TestInstallIn` replaces a production module for **every** test in the source set:

```kotlin
@Module
@TestInstallIn(components = [SingletonComponent::class], replaces = [NetworkModule::class])
object FakeNetworkModule {
    @Provides @Singleton fun provideOrdersApi(): OrdersApi = FakeOrdersApi()
}
```

A test then builds the real graph with that one module swapped:

```kotlin
@HiltAndroidTest
class OrderDetailTest {
    @get:Rule(order = 0) val hiltRule = HiltAndroidRule(this)
    @get:Rule(order = 1) val composeRule = createAndroidComposeRule<MainActivity>()

    @Inject lateinit var orders: OrderRepository
    @BindValue @JvmField val clock: Clock = FixedClock(Instant.parse("2026-01-01T00:00:00Z"))

    @Before fun setUp() = hiltRule.inject()

    @Test fun shows_the_order() {
        composeRule.onNodeWithText("Order #42").assertIsDisplayed()
    }
}
```

Rule order is not cosmetic: `HiltAndroidRule` must run first, or the Activity the Compose rule
launches is created before the graph exists. `@BindValue` binds a test field into the graph — right
for one value in one class, where a whole module would be ceremony — and it needs `@JvmField`,
because a plain Kotlin `val` compiles to a private backing field and Hilt rejects private ones.

`@UninstallModules(NetworkModule::class)` removes a module for one test class only, with `@BindValue`
fields supplying what it used to provide. It forces a separate component build for that class, so it
is the slower tool, for genuine one-offs.

The same tests run on the JVM under Robolectric: keep `@HiltAndroidTest`, the rule and
`hiltRule.inject()`, add `@RunWith(RobolectricTestRunner::class)` and
`@Config(application = HiltTestApplication::class)`, which names the test application directly — no
custom runner involved.

Plain unit tests use none of this: `OrderRepositoryImpl(FakeApi(), FakeDao(), testDispatcher)` is the
whole setup, and a unit test that needs Hilt is telling you the class under test reaches for the
graph instead of taking parameters.

## Plain Dagger

Hilt's components are generated against `Application`, `Activity`, `Fragment` and friends, so a
graph a Hilt build needs outside them — a JVM module or tool of that build, or a hierarchy Hilt does
not generate — is written through Dagger's own API, components by hand.

```kotlin
@Singleton
@Component(modules = [ExportModule::class])
interface ExportComponent {
    fun exporter(): ReportExporter

    @Component.Factory
    interface Factory { fun create(@BindsInstance config: ExportConfig): ExportComponent }
}

@Module
interface ExportModule {
    @Binds fun bindRenderer(impl: PdfRenderer): ReportRenderer
}

fun main(args: Array<String>) {
    val component = DaggerExportComponent.factory().create(ExportConfig.parse(args))
    component.exporter().run()
}
```

`main()` calling `DaggerExportComponent.factory()` is the composition root (`di-composition-root`),
and `@BindsInstance` is how a value the graph cannot construct — parsed arguments, an environment —
enters it.

A narrower lifetime is a `@Subcomponent` with its own `@Scope` — what Hilt generates for
`ActivityComponent` and friends, written out:

```kotlin
@Scope @Retention(AnnotationRetention.RUNTIME) annotation class JobScope

@JobScope
@Subcomponent(modules = [JobModule::class])
interface JobComponent {
    fun processor(): JobProcessor

    @Subcomponent.Factory
    interface Factory { fun create(@BindsInstance job: Job): JobComponent }
}
```

Inside the Android app itself, Hilt: writing those components by hand is the work Hilt exists to
remove. Which build takes which container: `di-composition-root` → "Choosing the Container".
