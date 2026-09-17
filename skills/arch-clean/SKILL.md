---
name: arch-clean
description: "Use when implementing Clean Architecture in a Kotlin project — client or server. Covers Domain / Data / Presentation layers as Gradle modules, use cases as invoke operators, repository interfaces in the domain, DTO ↔ entity ↔ domain mapping, the dependency rule, and testing each layer without frameworks."
---

# Clean Architecture in Kotlin

Business rules live in a module that compiles with no Android, no Spring and no database on its
classpath; everything else depends on it and it depends on nothing. In Kotlin that is a Gradle
dependency graph before it is a folder layout — the dependency rule holds because the build refuses
the import, not because a reviewer remembered it. What the presentation layer does with a use case is
`arch-mvvm`; the same inversion drawn for a server is `arch-hexagonal`.

> **Related skills:**
> - `arch-mvvm` — the presentation half: ViewModel, `UiState`, Compose binding, none of it repeated here
> - `arch-hexagonal` — the same inversion for a server, with adapters and transaction boundaries named
> - `arch-layered` — the cheaper server structure when the rules are thin and every use case would be a pass-through
> - `pkg-gradle-modules` — how the modules are actually declared: `api` vs `implementation`, version catalog, convention plugins
> - `pkg-kmp-source-sets` — `commonMain` layout, intermediate source sets, and the expect/actual rules `:data` obeys
> - `di-hilt` — binding a repository implementation to its domain interface on Android
> - `di-koin` — the same binding on KMP, Compose Desktop and Ktor
> - `di-spring` — the same binding in a Spring context, and why the container annotation stays out of the domain
> - `persistence-architecture` — source-of-truth and cache policy, which is what the repository implementation decides
> - `net-architecture` — the API boundary `:data` wraps, and where retry, paging and auth live
> - `error-architecture` — what a failure is before it becomes a `Result`, and the per-layer mapping
> - `architecture-choice` — the compass that sends you here, and the tiebreak that sends you back

## When to Use

- The active project guidance file's `## Stack` names `Clean Architecture`, or `architecture-choice`
  just landed there
- One ViewModel orchestrates three or more repositories, or the same business rule is written out in
  two of them
- The rules must be unit-testable with nothing framework-shaped on the classpath — no device, no
  Robolectric, no application context
- Android and iOS, or a client and a server, have to share the same rules, so the rules must move out
  of the UI module
- User asks "where do use cases go", "domain or data for the repository interface", "do I really need
  three models for one order", "how do I stop the domain from importing Android"

Not for the shape of one screen's state — that is `arch-mvvm`, or `arch-mvi` when the screen is a
state machine. Not for a CRUD service that maps HTTP to SQL and has no rules to protect: that is
`arch-layered`, and Clean over it is 40 files of indirection.

`references/detailed-guide.md` lies beside this file; its `## Contents` names the sections — read only the ones the table points to.

## When To Load The Reference

| Need | Reference sections |
|---|---|
| What the header comment means, and the time-type opt-in every sample assumes | `Reading These Files` |
| The entity, the port, and the domain error type | `Domain — Entity and Repository Port` |
| A use case with an actual rule in it, and the `Result` shape | `Domain — Use Cases` |
| The wire model and the API service that returns it | `Data — DTO and the Remote Source` |
| The persistence entity and the DAO behind the same repository | `Data — Room Entity and the Local Source` |
| DTO → domain, domain ↔ entity, and where nullability collapses | `Data — Mappers` |
| The implementation that picks a source and maps the failure | `Data — Repository Implementation` |
| A ViewModel that consumes the use case and nothing else | `Presentation — ViewModel` |
| One test per layer, and what each is allowed to touch | `Testing` |
| The four build files that enforce the rule, JVM and KMP | `Gradle Wiring` |

## Layers and the Dependency Rule

Three layers, two arrows, both pointing at the domain:

```
:app / :feature:orders  ──►  :domain  ◄──  :data
      presentation             rules       Room · Retrofit · Ktor · JPA
```

1. **The arrows are Gradle dependencies.** `:domain/build.gradle.kts` contains no
   `implementation(project(":data"))` and no `project(":app")`. That absence is the architecture, and
   it is one grep away in review — which is why it survives a year and a folder convention does not.
2. **`:domain` is `kotlin("jvm")` or a KMP module**, never `com.android.library`, and it declares one
   dependency: `kotlinx-coroutines-core`. `kotlin.time.Instant` and `kotlin.time.Clock` are stable
   since Kotlin 2.3 and available from 2.1.20 behind `@ExperimentalTime`; on 2.2 or earlier either
   add `-opt-in=kotlin.time.ExperimentalTime` or use `kotlinx.datetime.Instant` and `Clock` and keep
   `kotlinx-datetime` as a `:domain` dependency — which the calendar types (`LocalDate`, `TimeZone`)
   need on every version anyway. If a file there needs an import outside `kotlin.*`,
   `kotlinx.coroutines.*`, `kotlinx.datetime.*` and your own packages, either the type is wrong or
   the file is in the wrong module.
3. **Presentation depends on `:domain` only.** It sees use cases and entities. A ViewModel that can
   name `OrderDto` has a dependency the graph should have refused.
4. **`:data` depends on `:domain` and implements its interfaces.** Control flows outward at runtime —
   the use case calls into Room — while the compile arrow points inward. That inversion is the whole
   trick; everything else is bookkeeping.
5. **Nobody imports outward.** Not "nobody should": with the modules split, nobody can, and the
   failure is a compile error with a file and a line rather than a review comment.

| May import | `:domain` | `:data` | presentation |
|---|---|---|---|
| stdlib, `kotlinx-coroutines-core`, `kotlinx-datetime` | yes | yes | yes |
| `kotlinx.serialization`, Moshi, Jackson | no | yes | no |
| Room, SQLDelight, JPA, Exposed, jOOQ | no | yes | no |
| Retrofit, OkHttp, Ktor client | no | yes | no |
| Spring, Ktor server | no | at the adapter | that *is* the adapter |
| `androidx.lifecycle`, Compose | no | no | yes |

While the project is still one module, the rule is prose and decays like prose. A Konsist or ArchUnit
test asserting that no file in the `domain` package imports `android.`, `org.springframework.` or
`androidx.` buys most of the guarantee until the split is worth doing.

## Module Layout

```
settings.gradle.kts
├── :app             # Android application, or the server's main(); the composition root
├── :feature:orders  # Compose screens and ViewModels — optional, until it earns a module
├── :domain          # entities, repository interfaces, use cases; kotlin("jvm") or commonMain
└── :data            # DTOs, persistence entities, API services, mappers, repository impls
```

1. **Three modules is the floor and usually the ceiling.** `:app` + `:domain` + `:data` already
   enforces every arrow in the diagram. Add `:feature:*` when build time or parallel teams ask for
   it, not because the diagram in the article had them (`pkg-gradle-modules`).
2. **`:app` is the only module that sees everything**, because it is where the graph is assembled:
   it binds `OrderRepositoryImpl` to `OrderRepository` and nothing else knows both names.
3. **Package by feature inside a module, not by kind.** `com.acme.domain.orders` holds the entity,
   the port and the use cases together. A `model/` `usecase/` `repository/` trio inside `:domain`
   re-derives the layering the modules already gave you and hides which files change together.
4. **Split `:data` per source only when two teams own the sources.** `:data:remote` and `:data:local`
   are two more build files and one more `api` decision to get wrong; the repository implementation
   was already the seam.
5. **No `:core`.** See Mistake 4 — the module everything depends on has no dependency rule left to
   enforce.

## Use Cases

One class, one public function, named `invoke` so the call site reads as the verb:

```kotlin
// :domain
class GetOrders(private val repo: OrderRepository) {
    suspend operator fun invoke(id: CustomerId): Result<List<Order>> =
        repo.orders(id).map { orders -> orders.filterNot(Order::isArchived) }
}
```

1. **One public function.** A second one is a second use case. Private helpers are fine; a
   `refresh()` next to `invoke()` is two responsibilities sharing a constructor.
2. **Constructor dependencies only** — repositories, other use cases, a `Clock`. No `Context`, no
   `SavedStateHandle`, no field injection, no service locator inside the body.
3. **Stateless.** A use case must be safe to construct per call. A `var` in one is shared state with
   no owner: two screens read it and neither invalidates it.
4. **No dispatcher.** `withContext(Dispatchers.IO)` belongs where the blocking call actually is — the
   repository implementation in `:data`. A use case that names a dispatcher has an opinion about a
   collaborator's cost (`concurrency-coroutines`).
5. **No framework import, and no framework annotation either.** `@Service`, `@Singleton`,
   `@Inject` and `@HiltViewModel` all put a container on `:domain`'s classpath. Constructor
   parameters are enough; the binding happens in `:app` (`di-hilt`, `di-koin`, `di-spring`).
6. **A use case that adds no rule is a file, not a boundary.** Either it is genuinely the seam — two
   repositories, a policy, a decision — or the ViewModel takes the repository interface directly.
   Pick one convention per project and write it in the project guidance file.

Naming: verb phrases (`GetOrders`, `PlaceOrder`, `RefreshOrders`), because `getOrders(id)` at the
call site reads as a call. The `UseCase` suffix is a project convention, not an improvement; what
matters is that all of them agree.

**Return type.** Default to `Result<T>` with a sealed `DomainError : Exception()` in the failure slot,
and promote to your own sealed result the first time a caller writes a `when` over failure kinds —
`kotlin.Result` carries a `Throwable`, which is one bit at the call site until you inspect the
exception, and that inspection is the sealed type you declined to declare.

| Return | Use when | Cost |
|---|---|---|
| `Result<Order>` | the caller branches on success vs "something went wrong" | the failure slot is `Throwable`; reason-branching means a `when` over types |
| `sealed interface OrderOutcome`, or `Either` (Arrow) | the caller renders a different screen per failure — not found, not yours, offline | one more type per operation, mapped in every layer |
| `Flow<List<Order>>` | the screen follows a local database that is the source of truth | failures travel in-band and the flow must not complete on one |

Whichever it is, it is a project-wide decision, not a per-use-case one (`error-architecture`).

## Repositories

```kotlin
// :domain — the port. Domain vocabulary, domain types, nothing about transport or storage.
interface OrderRepository {
    suspend fun orders(customer: CustomerId): Result<List<Order>>
    fun observeOrders(customer: CustomerId): Flow<List<Order>>
    suspend fun refresh(customer: CustomerId): Result<Unit>
}
```

1. **The interface is declared in `:domain`, the implementation in `:data`.** Declared the other way
   round — the interface next to its implementation, "for cohesion" — the arrow flips and the domain
   depends on the data layer. This is the inversion the whole layout exists for.
2. **One repository per aggregate, not per data source.** `OrderRepository` decides between the local
   database and the API; `OrderRemoteSource` and `OrderLocalSource` are `internal` collaborators
   inside `:data` that the domain never hears about (`persistence-architecture`).
3. **Signatures use domain types only.** A `Pageable`, a `Response<T>`, an `HttpStatusCode`, a
   `@Entity` or a `PagingSource` in the port has moved `:data` into `:domain` under another name.
4. **The port says what, the implementation decides where.** Source-of-truth policy, staleness,
   retry, backoff, ETags, offline queueing — all `:data` (`persistence-architecture`,
   `net-architecture`).
5. **`suspend` and `Flow`, nothing else.** No callbacks, no `LiveData`, no `Call<T>`, no `Single<T>`:
   each of those drags a library into the module that is supposed to have none.
6. **Ports are narrow.** A repository with fourteen methods is usually two aggregates, and every
   fake in every test pays for all fourteen.

## Mapping

Three model families, one per concern that can change independently:

| Family | Lives in | Shaped by |
|---|---|---|
| `OrderDto` | `:data` | the wire: `@Serializable`, nullable fields, snake_case, dates as strings |
| `OrderEntity` (Room / JPA) | `:data` | the schema: flat columns, indices, foreign keys, a surrogate id |
| `Order` | `:domain` | the rules: non-null, value classes, no annotation from anyone |

```kotlin
// :data — mappers are internal extension functions, one per direction
internal fun OrderDto.toDomain(): Order = Order(
    id = OrderId(requireNotNull(id) { "order without id" }),
    customer = CustomerId(requireNotNull(customerId)),
    placedAt = Instant.parse(requireNotNull(placedAt)),
    status = status.toOrderStatus(),
    currency = requireNotNull(currency),
    lines = lines.orEmpty().map(OrderLineDto::toDomain),
)
```

1. **Mapping happens at the `:data` boundary**, inside or immediately beside the repository
   implementation. Nothing above `:data` has ever seen a DTO or a persistence entity.
2. **The mapper is where nullability collapses.** A wire `String?` becomes a domain `Instant` here,
   and a malformed payload becomes a typed failure here — not an NPE three layers up with a stack
   trace that names the composable.
3. **Two families suffice** when the app has no local persistence (no entity family), or when the
   wire shape and the rules shape genuinely coincide and the API is yours to change. Three families
   over a four-field CRUD screen is ceremony; three families over a wire you do not own is insurance.
   Say which case you are in, in the project guidance file, so the next person does not "fix" it.
4. **Never collapse the families by annotating the domain entity.** `@Serializable` or `@Entity` on
   `Order` saves one file and costs the dependency rule — see Mistake 2.
5. **Mappers are pure functions and tested as such** — a captured payload in, an entity out, no fake
   in sight. A `Mapper<In, Out>` interface bound through DI adds a seam nothing needs to mock.

## On the Server

Clean is the domain half of Hexagonal, in different words: a use case *is* the inside of an inbound
port, and a repository implementation *is* a driven adapter. Adopting both vocabularies for one
codebase gets you two names per file and no extra guarantee.

| Clean | Hexagonal |
|---|---|
| use case | inbound port / application service |
| controller, route, CLI command, consumer | driving adapter |
| repository interface in `:domain` | outbound port |
| repository implementation in `:data` | driven adapter |

- The container annotation stays out of `:domain`. A use case is a plain class with constructor
  parameters; a `@Configuration` in `:app` constructs it (`di-spring`).
- The transaction boundary is not the use case, because `@Transactional` on it would put Spring on
  `:domain`'s classpath. Put it on the adapter, or express the unit of work as an outbound port the
  domain calls — the trade-off, and what each choice costs, is `arch-hexagonal`.
- Everything else about ports, adapters and testing through them lives there too, and is not repeated
  here. If the service has no rules worth a domain module, neither skill applies: `arch-layered`.

## On KMP

- **`:domain` and `:data` are multiplatform modules with their code in `commonMain`.** If the UI is
  Compose Multiplatform, presentation joins them; otherwise each platform keeps its own presentation
  and the shared line is `:domain` plus `:data` (`pkg-kmp-source-sets`).
- **`commonMain` of `:domain` gets `kotlinx-coroutines-core` and optionally `kotlinx-datetime`.**
  Nothing else. A rule that needs a platform API is not a rule yet — express the need as an outbound
  port and let `:data` satisfy it per target.
- **`expect`/`actual` only in `:data`, and only for a driver**: the database driver, the HTTP engine,
  secure storage, a file location. `expect class GetOrders` means the rule differs per platform,
  which is the one thing the shared module exists to prevent.
- **Prefer an interface plus per-target implementations over `expect`/`actual` wherever DI already
  exists.** `expect`/`actual` is a compile-time hard link: a fake needs a whole extra target, while
  an interface needs a class (`di-koin`).

## Testing

The module graph is the test plan: the module with no frameworks gets the most tests and the fastest
ones, and the module that owns the frameworks pays for them.

**`:domain`** — plain `kotlin.test` or JUnit, `runTest` for suspend functions, a hand-written fake
repository with a settable result. No runner, no Robolectric, no application context, no container.
A domain test that needs any of those is reporting a dependency the module should not have.

**`:data`** — where the integration tests live. Mappers are pure-function tests over a captured
payload. Repository implementations get fakes for their sources plus assertions on the *policy*:
cache hit, refresh path, failure mapping. Against a real engine, on the server that is Testcontainers
with the actual database image; on the client it is `Room.inMemoryDatabaseBuilder`, which on Android
takes a `Context` and therefore runs as an instrumented test (Room 2.7's multiplatform builder takes
none and runs on the JVM). HTTP goes through Ktor's `MockEngine` or OkHttp's `MockWebServer`.

**Presentation** — the ViewModel test constructs it with **fake use cases**, which is why a use case
has exactly one function: the fake is three lines. Dispatchers, Turbine and the rest of the setup are
`arch-mvvm`, section Test Setup.

1. **Fake the port, not the framework.** A fake `OrderRepository` is the seam the interface exists
   for; mocking Retrofit to test a business rule tests the mock.
2. **A use case needing four mocks** is a use case orchestrating four things — split it, or admit the
   rule belongs one layer down.
3. **Keep `:data`'s container tests off the unit lane.** They are the slow ones, and a pull-request
   lane that runs them is a lane people learn to ignore (`release-ops`).

## When Appropriate

Adopt it when at least two hold:

- Two or more developers, a lifetime measured in years, and rules worth protecting
- The rules must be testable with nothing framework-shaped on the classpath
- Android and iOS (or a client and a server) must share those rules
- The same rule already exists, slightly differently, in two ViewModels or two controllers
- Feature work is parallel enough that a cross-team edge should be a compile error

Skip it when the app is CRUD over an API you control, when a solo project's "domain" is
`if (items.isEmpty())`, or when a server just maps HTTP to SQL (`arch-layered`).
`architecture-choice`'s When in Doubt row sends the undecided reader to MVVM; its Decision Matrix
names the two conditions — team size and a KMP shared layer — that flip the answer. That advice is
safe because extraction is additive: a ViewModel's constructor changes from a repository to a use
case wrapping it, and nothing else moves.

Two properties of the adoption itself:

- **It is a project decision, not a per-screen one.** The dependency rule is a property of the build.
  Contrast `arch-mvi`, which is legitimately chosen one screen at a time.
- **Adopt inward-out.** Move entities and the repository interfaces into `:domain` first; move the
  implementations into `:data` second; let presentation keep calling repositories until a real rule
  shows up and earns a use case. A big-bang split that lands with forty pass-through use cases is the
  failure this skill exists to prevent.

## Common Mistakes

1. **A use case that is a pass-through** — `suspend operator fun invoke(id: CustomerId) = repo.orders(id)`,
   forty times. Every one is a file, a constructor parameter, a binding and a fake, and none of them
   protects a rule. Either the rule is missing (put it there) or the layer is: let the ViewModel take
   the port and add use cases when something is actually decided.
2. **`@Serializable` on a domain entity** — one annotation, and `:domain` now has
   `kotlinx.serialization` on its classpath, the wire format changes whenever the rules do, and a
   field the API stopped sending cannot be deleted without breaking parsing. `@Entity`,
   `@JsonProperty` and `@ColumnInfo` fail the same way. Keep the DTO; write the mapper.
3. **A `Result` from the data layer carrying a DTO** — `Result<OrderDto>` (or a `Flow<OrderEntity>`)
   returned through the port, so the mapping happens in the ViewModel and the domain module is now
   the only place that *cannot* see the type its callers pass around. The port returns domain types
   or it is not a port.
4. **One giant `:core`** — `:core` holds entities, the network client, the theme, a `DateUtils` and
   the database, and every module depends on it. It has no dependency rule left to enforce, any
   change to it rebuilds the whole project, and "where does this go" always has the same wrong
   answer. Split by layer (`:domain`, `:data`) or by capability, never by "shared".
5. **`:domain` as an Android library module** — `id("com.android.library")` because the wizard
   offered it. Its tests now want a device or Robolectric, `android.text.TextUtils` is one
   autocomplete away, and the KMP move later is blocked by the plugin. `kotlin("jvm")` or
   `kotlin("multiplatform")` — and if a module truly needs an Android target under KMP, that is
   `com.android.kotlin.multiplatform.library` on `:data`, never here.
6. **A port shaped like the transport** — `getOrders(page: Int, perPage: Int, ifNoneMatch: String?)`.
   Paging cursors, ETags and status codes are `:data` vocabulary; the domain asked for a customer's
   orders. Now every caller and every fake knows how the API paginates, and the day it changes they
   all change.
7. **`withContext(Dispatchers.IO)` inside a use case** — the rule declares that its collaborator
   blocks, which is a fact about an implementation the domain is not supposed to know. Move it to the
   repository implementation, where the blocking call actually is (`concurrency-coroutines`).
8. **Mapping in the ViewModel** — presentation importing `OrderDto` or `OrderEntity` "because the
   repository already had it". The dependency graph either permits this, in which case the layering
   is decorative, or it does not, in which case someone added `implementation(project(":data"))` to
   the feature module and nobody noticed in review.
9. **A stateful use case** — a singleton with `var cachedOrders`, or a `MutableStateFlow` field. Two
   screens now share mutable state through an object whose lifetime nobody declared, and its tests
   pass or fail depending on order. Caching is a repository decision (`persistence-architecture`).
10. **`runCatching` in the repository implementation** — it catches `Throwable`, so a cancelled
    screen's in-flight load becomes `Result.failure(CancellationException)` and the ViewModel renders
    an error for a screen that no longer exists. Catch what you map and rethrow cancellation
    (`error-architecture`).
