---
name: arch-hexagonal
description: "Use when structuring a Kotlin JVM server as ports and adapters — an application core with no framework import, inbound ports driven by HTTP/CLI/queue adapters, outbound ports implemented by database/HTTP/queue adapters. Covers module layout, port design, where transactions and DI live, testing through ports, and when the ceremony pays off."
---

# Hexagonal Architecture — Ports and Adapters

The rules live in a module that compiles with no Spring, no Ktor and no database driver on its
classpath; everything that talks to the outside world is an adapter plugged into an interface the
core declared. It is `arch-layered` with the bottom arrow inverted, and it is worth its ceremony
exactly when that inversion buys something — a second external system, a second inbound channel, or
a test suite that must not boot a framework.

> **Related skills:**
> - `arch-layered` — the cheaper structure this replaces, and the three signals that justify replacing it
> - `arch-clean` — the same inversion in client vocabulary, and the deeper treatment of the domain half
> - `di-spring` — assembling the graph in `:app` with `@Configuration` beans, and the annotations that must stay out of `:core`
> - `di-koin` — the same assembly on Ktor, http4k or a CLI, plus the manual composition root
> - `pkg-gradle-modules` — how the four modules are actually declared: `api` vs `implementation`, version catalog, convention plugins
> - `persistence-jvm-orm` — what a persistence adapter sits on, and the transaction mechanics it hides
> - `net-architecture` — the inside of an outbound HTTP adapter: retry, timeouts, auth, paging
> - `error-architecture` — how a core failure crosses an adapter and becomes a status code
> - `architecture-choice` — the compass row that lands here, and the tiebreak that sends you back

## When to Use

- The active project guidance file's `## Stack` names `Hexagonal`, or `architecture-choice` just
  wrote it there
- One of `arch-layered`'s Signals to Move On has fired: a second external system, tests that must
  boot the framework to reach a rule, or services calling services in cycles
- The same operation is driven by more than one channel — an HTTP endpoint, a queue consumer, a
  nightly job and a support CLI all placing the same order
- An external system is contractual rather than permanent: a payment provider, a search index or
  another team's API that will be swapped, sandboxed or stubbed
- User asks "how do I keep the framework out of my domain", "where do transactions go if not on the
  service", "ports and adapters in Kotlin", "Layered or Hexagonal"

Not for a service that maps requests to rows: that is `arch-layered`, and ports over it are four
modules of indirection guarding no rule. Not for a UI — the client-side statement of the same
inversion is `arch-clean`.

## Shape

Four elements and one law. Everything on the outside depends on the core; the core depends on
nothing:

```
    driving adapters              the core                   driven adapters
  HTTP route      ─┐                                    ┌─►  OrderRepository  ─► the database
  CLI command     ─┼─►  PlaceOrder  ─►  domain rules ───┼─►  PaymentGateway   ─► the provider API
  queue consumer  ─┘    inbound port                    └─►  CurrentTime      ─► the system clock
                                                             outbound ports
```

- **The core** holds the domain model, the inbound ports, the outbound ports and the classes that
  implement the inbound ones. It is the only place a business decision is made, and it imports no
  framework — not the web one, not the container, not the ORM. That absence is the architecture.
- **Inbound ports** (driving side) are what the application offers, one interface per use case:
  `PlaceOrder`, `CancelOrder`, `QuoteShipping`. The core implements them.
- **Outbound ports** (driven side) are what the application needs, named for the need:
  `OrderRepository`, `PaymentGateway`, `CurrentTime`. The core declares them and calls them; adapters
  implement them.
- **Adapters** are the only classes that know a technology exists. A driving adapter translates a
  request, a message or a set of command-line flags into a call on an inbound port. A driven adapter
  translates a call on an outbound port into SQL, HTTP or a publish.

Control flows outward at runtime — a use case calls the database — while the compile arrow points
inward, because the interface belongs to the caller. That single inversion is the pattern; the module
layout below is how Kotlin makes it a compile error rather than a review comment.

## Module Layout

```
settings.gradle.kts
├── :core                   # domain model, inbound ports, outbound ports, use case implementations
├── :adapters:web           # controllers or routes; request DTOs; error mapping
├── :adapters:persistence   # outbound port implementations; entities; migrations
└── :app                    # main(), the DI wiring, configuration; depends on everything
```

| Module | Gradle dependencies | Framework on its classpath |
|---|---|---|
| `:core` | stdlib, `kotlinx-coroutines-core` | none |
| `:adapters:web` | `:core` | the web framework |
| `:adapters:persistence` | `:core` | the ORM and the driver |
| `:app` | `:core`, both adapters | the framework's runtime and DI |

1. **The dependency direction is the whole enforcement.** No `implementation(project(":adapters:web"))`
   in the core module's build file, ever. Nobody *can* import outward, and the failure is a compile
   error with a file and a line (`pkg-gradle-modules`).
2. **`:core` is `kotlin("jvm")`**, never the framework's own plugin, and it declares coroutines and
   nothing else. If a file there needs an import outside `kotlin.*`, `java.*`, `kotlinx.*` and your
   own packages, either the type is wrong or the file is in the wrong module — the rule is no
   framework, not no JDK.
3. **One adapter module per technology, not per feature.** `:adapters:web` plus
   `:adapters:persistence` plus `:adapters:payments` — a `:adapters:orders` holding a controller *and*
   a repository re-creates the coupling the split exists to remove.
4. **`:app` is the only module that can name two adapters**, because it is where the graph is
   assembled. It binds `ExposedOrderRepository` to `OrderRepository` and nothing else knows both
   names.
5. **A single-module variant is legal but weaker.** Packages `core`, `adapters.web`, `adapters.persistence`
   plus an ArchUnit or Konsist rule asserting nothing under `core` imports the framework buys most of
   the guarantee while the service is small. Split when the rule starts being argued with.

## Port Design

<!-- compile: jvm -->
```kotlin
// :core — inbound. One interface per use case, named for what the actor wants.
fun interface PlaceOrder {
    operator fun invoke(command: PlaceOrderCommand): Result<Order>
}

// :core — outbound. Named for what the core needs, never for what supplies it.
interface OrderRepository {
    fun save(order: Order): Order
    fun byId(id: OrderId): Order?
}

fun interface PaymentGateway {
    fun charge(amount: Money, method: PaymentMethod): Result<PaymentId>
}

fun interface CurrentTime {
    fun now(): Instant
}
```

1. **Inbound ports are named by intent.** `PlaceOrder`, `CancelOrder`, `QuoteShipping` — verb
   phrases, because the driving adapter's line reads as the thing the user asked for. An
   `OrderService` interface is a container of unrelated intents wearing one name.
2. **One method per use case.** `fun interface` with `operator fun invoke` makes the call site read
   as a call and the test double a lambda. Seven methods on one port means every driving adapter and
   every test depends on six intents it does not use.
3. **Outbound ports are named for the need, not the technology.** `PaymentGateway`, not
   `StripeClient`; `OrderRepository`, not `JpaOrderDao`. The core must not be able to tell which
   provider is behind the interface — that ignorance is what makes the provider swappable.
4. **Port signatures use domain types only.** A `ResponseEntity`, a `ResultSet`, a `JsonNode`, a
   `Pageable` or an `@Entity` in a signature has moved an adapter into the core under another name.
5. **The core owns the interface, the adapter owns the implementation, and the names say so**:
   `OrderRepository` in `:core`, `ExposedOrderRepository` or `JpaOrderRepository` in
   `:adapters:persistence`. Declared the other way round — the interface next to its implementation
   "for cohesion" — the arrow flips and the core depends on the adapter.
6. **Ports are narrow, because every fake pays for every method.** A repository with fourteen
   functions is usually two aggregates and fourteen lines of boilerplate in each test.
7. **Count the outbound ports and you have counted the external world**: one per external system,
   plus the ambient ones — clock, id generator, randomness — which exist so a test can make time and
   identity deterministic without a mocking framework.

## Where Things Live

**Transactions.** Not in the core as an annotation: `@Transactional` on a use case puts Spring on
`:core`'s classpath, and what it does then depends on how `:app` builds the class. Returned from a
Spring `@Bean` method it is proxied like any bean — or, being a final Kotlin class under Spring Boot's
class-based proxies, fails the context at startup; built by Koin or in `main()` it does nothing. Two
placements are correct, and a project picks one:

| Placement | Use when | Cost |
|---|---|---|
| Inside the persistence adapter | one use case writes one aggregate — the port method *is* the unit of work | a use case that must write two aggregates atomically has nowhere to say so |
| An outbound `UnitOfWork` port the core calls | one use case writes through two ports and they must commit together | the core now names a concept that only exists because a database does |

<!-- compile: ktor -->
```kotlin
// :core — the port, if you need one. No framework word appears in it.
interface UnitOfWork {
    fun <T> inTransaction(block: () -> T): T
}

// :adapters:persistence — Exposed 1.x; Spring: TransactionTemplate; a suspending core: suspendTransaction
class ExposedUnitOfWork : UnitOfWork {
    override fun <T> inTransaction(block: () -> T): T = transaction { block() }
}
```

**DI.** `:app` assembles the graph and is the only module that may — Spring `@Configuration` with
`@Bean` functions constructing core classes, Koin `module { single { ... } }`, or plain constructor
calls in `main()`. The core carries no `@Service`, `@Singleton`, `@Inject` or `@ApplicationScoped`:
constructor parameters are the whole declaration, and `di-spring` or `di-koin` describes the binding.

**Configuration.** Read in `:app` and passed to core constructors as domain values — a
`Duration`, a `Money`, a `RetryPolicy`. A `@Value` or an `@ConfigurationProperties` class reachable
from the core is the framework arriving through the back door.

**Mapping.** At each adapter's outer edge: request DTO ↔ domain in `:adapters:web`, persistence
entity ↔ domain in `:adapters:persistence`. The core has never seen either type.

**Errors.** The core returns its own failures — a sealed hierarchy, `Result` or `Either`, decided
once for the project. The web adapter maps them to status codes and problem details, the CLI adapter
to exit codes; the mapping table lives in the adapter, because a status code is a transport fact
(`error-architecture`).

## Framework Notes

**Spring.** `:core` is a plain `kotlin("jvm")` library module with no Spring dependency at all — not
even `spring-context` for the annotations. The adapters carry `@RestController`, `@Repository` and
`@Transactional`; `:app` carries `@SpringBootApplication` and the `@Configuration` that constructs
core classes as beans. Component scanning never reaches `:core`, and that is the check: if the core
would have to be scanned to work, something in it is annotated.

**Ktor.** The routes *are* the inbound adapter. A `Route.orderRoutes(placeOrder: PlaceOrder)`
extension takes ports as parameters, so the adapter has no lookup and no container inside it; the
application module in `:app` installs the plugins and passes the constructed ports in. Exposed's
`transaction { }` never appears above `:adapters:persistence`.

**Micronaut and Quarkus.** Same as Spring, with one gain: compile-time DI cannot scan what has no
annotation processor on it, so a `:core` that declares none is enforced by the build rather than by
configuration.

**http4k.** `HttpHandler` is `(Request) -> Response` — already a port shape, which makes the whole
framework naturally hexagonal. An inbound adapter is a `routes("/orders" bind POST to placeOrder)`
value closing over your ports; an outbound HTTP adapter is an `HttpHandler` a test replaces with an
in-memory function, no server and no socket involved. If the team is on http4k, the ceremony this
skill describes is mostly already paid for.

## Testing

The split is the test plan: the module with no framework gets the most tests and the fastest ones,
and the modules that own the frameworks pay for them.

**The core, with a fake for every outbound port.** No mocking framework is needed and none should be
used — the ports are narrow by construction, so a fake is a class with a map in it, and it can hold
the invariants a mock cannot (an id that increments, a row that is really there on the next read).

<!-- compile: jvm-test -->
```kotlin
class InMemoryOrders : OrderRepository {
    private val saved = mutableMapOf<OrderId, Order>()
    override fun save(order: Order): Order = order.also { saved[it.id] = it }
    override fun byId(id: OrderId): Order? = saved[id]
}

@Test
fun placeOrder_gatewayRefuses_fails() {
    val placeOrder = PlaceOrderUseCase(InMemoryOrders(), RefusingGateway, FixedTime(now))
    assertTrue(placeOrder(command).isFailure)
}
```

**Every adapter against the real thing.** The persistence adapter runs on Testcontainers with the
actual database image, because a fake database proves nothing about the SQL the adapter writes. The
web adapter runs on the framework's own test host — `@WebMvcTest` with `MockMvc` on Spring,
`testApplication` on Ktor, and on http4k the `HttpHandler` invoked directly in memory. An outbound
HTTP adapter runs against a stub server or, on http4k, a replaced handler.

**One contract test per outbound port, run twice.** The same test class, executed against the fake
and against the real adapter, is what stops the fake from drifting into a fiction the core is
written for. It is the only place where "the fake behaves like the database" is an assertion rather
than a hope.

1. **Fake the port, never the framework.** Mocking the ORM to test a pricing rule tests the mock.
2. **A use case that needs five fakes is orchestrating five things** — either it is really a policy
   over two use cases, or a port is doing too little and two of them are one.
3. **Keep the container-backed adapter tests off the pull-request lane.** They are the slow ones, and
   a lane that runs them is a lane people learn to ignore.
4. **`:app` gets one test: the graph builds.** A context that starts, or on Koin the definition walk
   `di-koin` → "Testing" describes, catches the missing binding, which is the only failure mode
   assembly has.

## When Worth It

One signal is enough to move; two make the move overdue:

- **A second external system**, and one of them must be swappable, sandboxed or faked — the signal
  `arch-layered` names first, and the one that most often decides it alone
- **More than one inbound channel** driving the same operations: HTTP plus a queue consumer, plus a
  scheduler, plus a support CLI. Four adapters over one core, instead of four copies of a rule
- **The rules must be testable with nothing framework-shaped on the classpath**, because the suite
  that boots the framework has become slow enough to skip
- **A team that will be replaced**, or a framework that will be: the core is the part meant to
  outlive both, and it is the part a new team can read without knowing the stack
- Rich enough rules that the core is not just forwarding — a pricing engine, a settlement policy, a
  scheduling constraint

Skip it when the service maps requests to rows over one database (`arch-layered`), when the "core"
would be a folder of pass-through use cases, or when nobody on the team has run the pattern before
and the domain is not complex enough to teach it — `architecture-choice` asks about familiarity for
exactly this row.

Two properties of the adoption itself:

- **It is a project decision, not a per-endpoint one.** Half a codebase in ports and the other half
  in layers is neither, and the boundary between them is where the rules go to hide.
- **Adopt inward-out, one use case at a time.** Extract the interfaces an existing service already
  depends on, move them and the rules into `:core`, leave the framework classes behind as adapters.
  A big-bang split that lands with twelve pass-through ports is the failure this skill exists to
  prevent.

Clean Architecture is the domain half of this pattern in other words — a use case is the inside of an
inbound port and a repository implementation is a driven adapter — so pick one vocabulary per
codebase and read `arch-clean` for the deeper treatment of the domain, not for a second set of names.

## Common Mistakes

1. **A port per entity instead of per use case** — `OrderPort` with `create`, `update`, `delete` and
   `findAll`. That is the CRUD table with an interface in front of it: the ports now change whenever
   the schema does, every adapter depends on all four methods, and not one of them names something a
   user asked for.
2. **The core importing JPA annotations** — `@Entity` and `@Id` on the domain model, to save writing
   a mapper. Hibernate is now on `:core`'s classpath, the model needs the no-arg and all-open plugins
   to be instantiable, lazy proxies escape into the rules, and the schema starts steering the domain
   instead of the other way round. Keep the persistence entity in the adapter and write the mapper.
3. **Adapter logic leaking into the core** — an HTTP status code in a use case's return type, a retry
   policy, a SQL fragment, a JSON field name, a `HttpServletRequest` read through a thread-local. Each
   one is a technology decision made where it cannot be swapped, and it is invisible in review because
   the file still lives in the right module.
4. **Ports declared in the adapter** — the interface next to its implementation because they "belong
   together". The compile arrow now points outward and the core depends on the ORM; the layout still
   looks hexagonal in the directory tree.
5. **`@Transactional` on a use case** — the container arrives on the core's classpath, and whether the
   transaction exists is decided by the composition root: a Spring `@Bean` proxies it, Koin or
   `main()` leaves it inert, and a final class under class-based proxies stops the context from
   starting. Put the boundary in the adapter or express it as a `UnitOfWork` port.
6. **Logic in `:app`** — the composition root grows an `if`, a mapping, or a "small" orchestration
   between two ports. It is the one module with no boundary above it and no test below it, so
   whatever lands there is untested by construction. `:app` wires and starts; that is all.
7. **One adapter module per feature** — `:adapters:orders` holding a controller, a repository and a
   payment client. Every technology change now touches every feature module, which is the coupling
   the split was for.
8. **Ports mocked instead of faked** — `every { repo.byId(any()) } returns order` in forty tests. The
   fake would have been ten lines once, and the mocks encode an assumption about call order that the
   real adapter never promised.
9. **Hexagonal over a CRUD service** — four modules, twelve ports and a core whose every use case
   forwards to one repository call. The indirection is real and the guarantee is zero;
   `architecture-choice`'s When in Doubt row says Layered until a signal fires, and it means it.
