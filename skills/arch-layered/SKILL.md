---
name: arch-layered
description: "Use when structuring a Kotlin JVM server or CLI as layers — controller / route → service → repository → domain — with Spring Boot, Ktor, Micronaut, Quarkus, http4k, Clikt or kotlinx-cli. Covers layer responsibilities, transaction boundaries, DTO vs entity vs domain, per-framework mapping of the layers, and the signals that layering has run out of steam."
---

# Layered Architecture on the JVM

Four layers and one direction: an entry point parses transport, a service holds the rules and owns
the transaction, a repository talks to the store, and a domain model carries the data through all
three. Every JVM framework already assumes this shape, so it costs almost nothing to adopt and
almost nothing to read — the expensive part is noticing the day it stops fitting, which is the last
section here.

> **Related skills:**
> - `arch-hexagonal` — where to go the day the signals at the bottom of this file fire
> - `arch-clean` — the same move on a client, or when the rules deserve a module with no framework on its classpath
> - `di-spring` — how the layers get constructed when the container is Spring's, and what `@Service` actually buys
> - `di-koin` — the same assembly on Ktor, http4k or a CLI, plus the manual-graph option
> - `persistence-jvm-orm` — what the repository layer sits on: JPA, Exposed, jOOQ, Spring Data JDBC, and their transaction mechanics
> - `persistence-migrations` — the schema under the repository, and how a change to it ships
> - `net-openapi` — where the entry point's DTOs come from, or go, once the API has a spec
> - `error-architecture` — how a failure crosses the layers and becomes a status code or an exit code
> - `concurrency-coroutines` — which dispatcher each layer gets, and where `suspend` stops
> - `architecture-choice` — the compass that sends you here, and the rows that send you elsewhere

## When to Use

- The active project guidance file's `## Stack` names `Layered`, or `architecture-choice` just
  wrote it there
- A JVM server that mostly maps requests to rows: CRUD, reporting, an admin API, a webhook receiver
- A CLI, where the commands are entry points and everything below them is the same three layers
  (`architecture-choice` makes this its default: command → service, thin)
- An existing service where nobody can say what a class is allowed to call, and the first job is to
  name the layers before moving anything
- User asks "where does this logic go", "controller or service", "where do I put `@Transactional`",
  "should the entity be the response body", "do I need Hexagonal for this"

Not for the shape of a screen's state — that is `arch-mvvm`. Not when the rules must compile with no
framework on the classpath, or a second implementation of an external system has to be swappable:
that is `arch-hexagonal`, and the signals that take you there are named below.

## The Four Layers

Data flows one way in, one way out, and no layer ever calls the one above it:

```
Entry Point → Business Logic → Data Access → (Database / External Systems)
 controller       service        repository            JDBC · HTTP · queue
 route            use case       DAO
 CLI command                     gateway
```

**Entry point** — transport, and nothing else. It parses a request into arguments, calls exactly one
service method, and turns the answer into a response. HTTP status codes, headers, content
negotiation, argument parsing and exit codes live here and nowhere else.

**Service** — the rules, the orchestration and the transaction. It is the only layer that may call
two repositories in one operation, and the only layer where a decision is made. It speaks domain
types and knows nothing about the request that started it.

**Repository** — persistence, and nothing else. One aggregate per repository, domain types in and
out, no rule about *whether* a thing should be saved — only about how.

**Domain** — the data the other three pass around: `Order`, `OrderId`, `OrderStatus`. Plain Kotlin
classes with domain invariants in their constructors, no transport concern, no persistence concern.

The layers are packages first (`api`, `service`, `repository`, `domain`) and Gradle modules only if
build time or team boundaries ask (`pkg-gradle-modules`). Unlike Clean's dependency rule, layering
does not depend on the build to hold: it is a convention, and a convention decays. An ArchUnit or
Konsist test asserting that nothing in `repository` imports `service` and nothing in `domain`
imports either is twenty lines and buys the guarantee back.

## Per-Framework Mapping

The same four rows, spelled in each framework's own vocabulary. Nothing about the shape changes
between the columns — only the annotation does, which is the point.

| Layer | Spring Boot | Ktor | Micronaut | Quarkus | http4k | CLI | Generic |
|---|---|---|---|---|---|---|---|
| Entry point | `@RestController` | Route handler | `@Controller` | JAX-RS `@Path` resource | `HttpHandler` / `routes { }` | Clikt `CliktCommand.run()`, kotlinx-cli `Subcommand.execute()` | Handler / Endpoint |
| Business logic | `@Service` | UseCase / Service | `@Singleton` | `@ApplicationScoped` | plain class | service | Service / UseCase |
| Data access | `@Repository` / Spring Data | Repository / DAO | `@Repository` / Micronaut Data | Panache repository | plain class | repository | Gateway / Repository |
| Domain | Entity / DTO | Domain model | Entity / DTO | Entity / domain model | data class | data class | Domain model |

Three notes the table cannot carry:

- **Compile-time DI changes nothing.** Micronaut and Quarkus resolve the graph at build time instead
  of at startup; the layers, their responsibilities and the transaction boundary are identical
  (`architecture-choice` says the same in its Micronaut / Quarkus row).
- **http4k has no annotations to hang layers on**, so the layers are plain classes and the
  discipline is entirely yours. The upside is that its `HttpHandler` is already a function boundary,
  which is why `arch-hexagonal` is a shorter trip from here than from anywhere else.
- **A CLI usually has three layers, not four**, because the domain model is often a single data
  class. Command → service → repository, and drop the repository too when the only store is stdout.

## Rules

Seven, and a violation of any one of them is the thing to fix in review:

1. **Entry points handle HTTP/transport only — no business logic.** A controller that decides
   anything is a controller two callers will need, and the second caller is a scheduler that has no
   HTTP request to hand it.
2. **Services contain business rules and orchestration — no direct persistence or HTTP concerns.**
   No `EntityManager`, no `Connection`, no `HttpServletRequest`, no `ApplicationCall`. A service that
   knows it was reached over HTTP cannot be reached any other way.
3. **Repositories contain persistence logic — no business rules.** `findActiveOrders` is fine;
   `placeOrderIfStockAllows` is a service that was written in the wrong file, and the rule it holds
   is now invisible to everyone reading the service.
4. **Domain models carry domain data — no transport or persistence concerns.** In practice: no
   `@JsonProperty`, and no `@Entity` unless you have consciously accepted the collapse the DTOs
   section describes.
5. **No cyclic dependencies between layers, packages or modules.** Not upward, and not sideways:
   `OrderService` ↔ `InvoiceService` is a cycle even though both sit on the same layer, and the
   container will tell you so at startup after you have already built it.
6. **Data flows down via parameters and up via return values — never through shared mutable state.**
   No `var` field on a singleton service, no request state parked in a thread-local, no bean property
   written by one call and read by the next. Two concurrent requests share every singleton in the
   container.
7. **Non-HTTP entry points (message queues, schedulers, CLI) follow the same layering: they delegate
   to services, never contain business logic.** Detailed in its own section below, because this is
   the rule that breaks first.

## Transaction Boundary

**The transaction starts and ends on the service method.** That is the only layer that knows which
group of writes must succeed together, which is the definition of the boundary.

```kotlin
@Service
class OrderService(
    private val orders: OrderRepository,
    private val stock: StockRepository,
) {
    @Transactional
    fun place(command: PlaceOrder): Order {
        val reserved = stock.reserve(command.sku, command.quantity)
        return orders.save(Order.from(command, reserved))
    }
}
```

- **Never on the controller.** The transaction then spans response serialization, and a lazy
  association loaded during serialization is a query inside a request-scoped transaction that nobody
  can see in the service (`persistence-jvm-orm`).
- **Never on the repository.** Each repository call gets its own transaction, so the two writes above
  cannot roll back together — the reservation survives an order that failed to save. This is the
  single most common layering bug that reaches production, because it looks correct in every test
  that exercises one method at a time.
- **Ktor with Exposed puts it in the same place**, spelled as a function instead of an annotation:
  `transaction { }` in a blocking service, `newSuspendedTransaction { }` in a `suspend` one — wrapping
  the service method's body, not each repository call.

```kotlin
class OrderService(
    private val orders: OrderRepository,
    private val stock: StockRepository,
) {
    suspend fun place(command: PlaceOrder): Order = newSuspendedTransaction {
        val reserved = stock.reserve(command.sku, command.quantity)
        orders.save(Order.from(command, reserved))
    }
}
```

- **Micronaut and Quarkus use `@Transactional` on the service exactly as Spring does**, and http4k
  and a CLI use whatever their persistence library offers — in the service method, by construction,
  because there is no framework to put it anywhere else.
- **The annotation on the service is a Layered privilege.** `arch-clean` and `arch-hexagonal` cannot
  take it: their core must not import the container, so the boundary moves outward into an adapter or
  a `UnitOfWork` port. Here the service already lives inside the framework's module, so the cheapest
  correct answer is also the idiomatic one.
- **Read the framework's proxy rules once.** On Spring, `@Transactional` works through a proxy: a
  `private` method, or one service method calling another on `this`, gets no transaction at all, and
  Kotlin classes need the all-open plugin to be proxyable in the first place (`di-spring`).

## DTOs

Three shapes, and the boundary between them is the entry point:

| Shape | Lives in | Shaped by |
|---|---|---|
| `PlaceOrderRequest`, `OrderResponse` | entry point | the wire: nullable fields, strings for dates, whatever the client sends |
| `OrderRow` / `@Entity OrderEntity` | repository | the schema: columns, indices, a surrogate id |
| `Order` | domain | the rules: non-null, value classes, invariants in the constructor |

1. **Request and response DTOs exist at the entry point only.** They are declared next to the
   controller, mapped there, and no service signature mentions them. A service taking a
   `PlaceOrderRequest` is a service the scheduler cannot call without inventing an HTTP request.
2. **Validation happens at the entry point, on the DTO** — before any rule runs, so the service can
   assume shape and only check meaning. `jakarta.validation` annotations plus `@Valid` on Spring,
   Micronaut and Quarkus; on Ktor and http4k, explicit checks in the handler or a validation library,
   since there is no annotation processor to lean on.
3. **Shape validation is not a business rule.** "quantity must be a positive integer" is the DTO's
   job; "quantity must not exceed available stock" is the service's. Split them there and neither
   layer duplicates the other.
4. **Two shapes are legitimate when the service is CRUD over a schema you own** — let the entity be
   the domain model and keep only the DTO family. Say so in the project guidance file, because the
   next reader will otherwise "fix" the missing layer.
5. **Never let the persistence entity be the response body.** That is the collapse that costs
   something: the schema becomes the public contract, a renamed column is a breaking API change, and
   a lazy association serializes into a query storm or an exception, depending on the day.
6. **Map with extension functions, one per direction**, next to the DTO. `toDomain()` at the entry
   point, `toResponse()` on the way out; a `Mapper<In, Out>` interface bound through DI is a seam
   nothing needs to mock.

```kotlin
// entry point — the only layer that knows these two types exist
data class PlaceOrderRequest(@field:NotBlank val sku: String, @field:Positive val quantity: Int)

@PostMapping("/orders")
fun place(@Valid @RequestBody body: PlaceOrderRequest): OrderResponse =
    service.place(PlaceOrder(Sku(body.sku), body.quantity)).toResponse()
```

## Non-HTTP Entry Points

A scheduler, a message consumer and a CLI command are entry points, and rule 7 applies to them
unchanged: parse, delegate to a service, format the result. They are where layering breaks first,
because they arrive later than the controllers and nobody thinks of them as controllers.

| Entry point | Spring Boot | Ktor / http4k | Micronaut | Quarkus |
|---|---|---|---|---|
| Scheduler | `@Scheduled` | a coroutine on the application scope | `@Scheduled` | `@Scheduled` |
| Message consumer | `@KafkaListener`, `@RabbitListener` | client library callback | `@KafkaListener` | `@Incoming` |
| CLI command | `CommandLineRunner` | `CliktCommand.run()`, `Subcommand.execute()` | `PicocliRunner` | `@QuarkusMain` |

1. **The handler body is two or three lines.** Deserialize the message or the flags, call one service
   method, acknowledge or print. If it is longer, the rule that grew there is invisible to the HTTP
   path that needs it too.
2. **The service does not learn which entry point called it.** No `source: String` parameter, no
   `if (fromQueue)`. Two behaviours mean two service methods with honest names.
3. **Retry, acknowledgement and idempotency are transport concerns**, so they belong to the consumer
   next to the broker's semantics — but the *idempotency key* is a domain value the service checks
   (`error-architecture`).
4. **A scheduled job that must not run twice across replicas needs a lock**, and the lock is a
   persistence concern with a repository behind it, not a `synchronized` block in the job.
5. **A CLI's exit code is its status code.** Map the service's failure to it in the command, the way
   a controller maps to 4xx — one mapping table, one layer.

```kotlin
class PlaceCommand(private val service: OrderService) : CliktCommand() {
    private val sku by option().required()
    private val quantity by option().int().default(1)

    override fun run() = echo(service.place(PlaceOrder(Sku(sku), quantity)).id.value)
}
```

## Signals to Move On

Layering is the right answer until one of these is true. Each is a fact about the codebase, not a
feeling about it, and each points at `arch-hexagonal`:

1. **A second external system arrives.** The service already talks to the database; now it also
   talks to a payment provider, a search index or another team's API — and one of them has to be
   swappable, or faked in a test, or replaced next quarter. Layering has one outward direction and no
   name for "the thing behind the boundary"; ports do.
2. **Tests have to boot the framework to reach a rule.** When asserting a pricing decision requires
   `@SpringBootTest`, a container start and a database, the rule is welded to the framework. The unit
   lane gets slow, then gets skipped, then stops catching anything. Hexagonal's core is testable with
   fakes and no framework at all.
3. **Services call services in cycles.** `OrderService` needs `InvoiceService` which needs
   `OrderService`; someone breaks it with a `@Lazy`, an `ApplicationContext` lookup or a setter, and
   the graph now has an edge nobody can see. A cycle between services means the rule belongs to
   neither — in ports and adapters it becomes a use case in the core with both collaborators as
   outbound ports.

One signal is enough to start the conversation; two make the move overdue. `architecture-choice`
states the same tiebreak from the other side — *Layered, until the second external system arrives or
tests need the framework out.* The migration is incremental: extract the service's collaborators into
interfaces it owns first, then move the interfaces and the rules into a module with no framework
dependency. What lands there is `arch-hexagonal`, and its domain half is `arch-clean`.

## Common Mistakes

1. **Business logic in the controller** — a `when` over statuses, a price calculation, or a second
   repository call inside the handler. It works until the scheduler needs the same behaviour and has
   no request to build; then the rule is copied, and the two copies drift within a month.
2. **`@Transactional` on the repository** — every call gets its own transaction, so a service that
   writes twice cannot roll back as a unit, and a failure halfway leaves the first write committed.
   Every single-method test still passes.
3. **`@Transactional` on the controller** — the transaction now spans response serialization, so a
   lazy association is fetched during JSON writing, inside a boundary the service can neither see nor
   close. The read-only flag, the timeout and the rollback rules end up describing a request rather
   than an operation.
4. **The persistence entity as the response body** — one `@Entity` class annotated with
   `@JsonProperty` and returned from the controller. The schema is now the public contract: a column
   rename is a breaking change, a new column leaks, and the lazy fields either explode or fetch the
   whole graph.
5. **A controller calling a repository directly** — "it is just a read, the service would be a
   pass-through". Then the read grows a filter, the filter grows a rule, and the rule lives in the
   controller with no transaction around it and no way to reach it from the consumer.
6. **A service that reaches for the request** — `HttpServletRequest`, `ApplicationCall`, a
   `RequestContextHolder` lookup, or a header read through a thread-local. The service is now
   HTTP-only in fact while claiming to be transport-agnostic in the package name, and its unit test
   needs a request scope to exist.
7. **State on a singleton service** — `private var currentUser`, or a cache field written per call.
   In a container, one instance serves every concurrent request; the bug is a wrong answer under load
   and it does not reproduce locally. Rule 6 exists for exactly this.
8. **One service per entity, mirroring the repositories** — `OrderService` forwarding to
   `OrderRepository` method for method. The layer buys nothing except a second file to open, and the
   moment a real operation spans two entities it becomes a service-to-service call and then a cycle.
   Name services after operations the business has a word for, not after tables.
9. **Blocking JDBC inside a `suspend` route** — Ktor or a coroutine-based handler calling a blocking
   repository on the request dispatcher. Layering is intact and throughput is not; the repository is
   the layer that declares its own cost with `withContext` (`concurrency-coroutines`).
