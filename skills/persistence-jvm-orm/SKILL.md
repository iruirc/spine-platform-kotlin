---
name: persistence-jvm-orm
description: "Use when choosing and using a database layer on a Kotlin JVM server — JPA/Hibernate (Spring Data JPA), Exposed, jOOQ, Spring Data JDBC. Covers the decision, Kotlin+JPA pitfalls (all-open, no-arg, data class entities, equals, lazy loading), transaction boundaries, N+1, connection pools, and repository tests with Testcontainers."
---

# JVM Database Layers

Four ways a Kotlin server talks to a relational database, the decision between them, and what each
gets wrong in Kotlin specifically — entities written as `data class`, a compiler that makes
everything `final` under a framework that needs it `open`, a lazy association read after its
transaction closed. The boundary above the database is `persistence-architecture`; the schema
underneath it belongs to `persistence-migrations`.

> **Related skills:**
> - `persistence-architecture` — the repository boundary this engine hides behind, and the rule that a managed entity never leaves the layer that loaded it
> - `persistence-migrations` — who owns the schema this code validates against, and how it changes without downtime
> - `arch-layered` — owns the transaction boundary: it is the service method, on every framework
> - `arch-hexagonal` — the same boundary when the core may not import a container: an adapter or a `UnitOfWork` port
> - `arch-clean` — the entity/domain split, and why the mapper between them is not boilerplate
> - `di-spring` — the all-open plugin story, `@ConfigurationProperties` for the datasource, and test slices
> - `concurrency-coroutines` — which dispatcher a blocking JDBC call belongs on, and what virtual threads changed
> - `error-architecture` — turning a constraint violation into a typed domain error instead of a 500

## When to Use

- A new Kotlin server needs its first table and nobody has picked JPA, Exposed, jOOQ or JDBC
- User asks "why does Hibernate say no default constructor", "why is my entity `final`",
  "why did one query become two hundred", "how big should the pool be", "how do I test a
  repository without H2"
- Review finds `data class` under `@Entity`, `FetchType.EAGER`, `open-in-view` left on,
  `ddl-auto=update`, or a repository method annotated `@Transactional`
- The symptom is a `LazyInitializationException` in a controller, a p99 that collapses under
  concurrency, or `HikariPool-1 - Connection is not available, request timed out`

Not for the client-side database (`persistence-room-sqldelight`), not for what the persistence
layer is *for* (`persistence-architecture`), not for schema change (`persistence-migrations`), and
not for where the transaction goes relative to the layers — that is `arch-layered`, and this skill
adds only what JPA's proxy makes different.

`references/detailed-guide.md` lies beside this file; its `## Contents` names the sections — read only the ones the table points to.

## When To Load The Reference

| Need | Reference sections |
|---|---|
| The shared `Order`/`OrderRepository` types every engine section assumes | `The Domain Side` |
| Write a JPA entity in Kotlin without tripping over `final` or `equals` | `JPA — Entity and Gradle Plugins` |
| Load an aggregate in one query and return it as domain | `JPA — Repository and the Read Path` |
| Test a repository against the real database | `JPA — @DataJpaTest with Testcontainers` |
| Declare Exposed tables and write DSL queries | `Exposed — Tables and DSL` |
| Put Exposed behind a port in a suspending Ktor service | `Exposed — Repository on Ktor` |
| Test Exposed without a Spring context | `Exposed — Testcontainers Test` |
| Generate typed SQL from the migrated schema | `jOOQ — Codegen and a Typed Query` |
| Save an aggregate whole with no session or dirty checking | `Spring Data JDBC — Aggregate Root` |
| Prove a read path issues the number of queries you think | `Finding an N+1 with Hibernate Statistics` |
| Size the connection pool | `HikariCP Sizing` |

## Decision

| Situation | Take | Because |
|---|---|---|
| Spring Boot, the team knows JPA, and the model is entity-shaped — real associations, aggregates loaded and mutated | JPA / Hibernate via Spring Data JPA | derived query methods, dirty checking, cascades and `@EntityGraph` are already written; the cost is a session whose rules you must learn, and this skill is mostly about those rules |
| Ktor or any server without a Spring container, and the team wants Kotlin rather than annotations | Exposed | a Kotlin DSL over SQL with no annotation processor, no proxies and no session: `transaction { }` is the whole lifecycle, and `newSuspendedTransaction` makes it coroutine-shaped |
| SQL *is* the product — reporting, analytics, window functions, CTEs, bulk statements | jOOQ | the schema is generated into typed Kotlin from the real database, so a renamed column is a compile error; you write SQL and get type safety instead of writing objects and getting SQL |
| Aggregates you load whole and save whole, no lazy loading, no partial updates | Spring Data JDBC | Spring Data's repositories without a persistence context: `save()` writes the aggregate, deletes the removed children, and nothing happens that you did not ask for |
| A handful of statements and a `RowMapper` would do | `JdbcClient` (Boot 3.2+) or `JdbcTemplate` | an ORM you use for four queries is four queries plus a framework; the migration tool still owns the schema |
| Kotlin Multiplatform, or an Android client | none of these | that is `persistence-room-sqldelight` — none of the four run on Kotlin/Native |

Two rules that outlive the choice:

1. **The schema is never generated by the code that reads it.** `ddl-auto` is `validate` in every
   environment that is not a throwaway test, and the tables come from Flyway or Liquibase
   (`persistence-migrations`). An ORM that can create your schema will also silently disagree with
   it later.
2. **Two engines in one service is a decision, not an accident.** jOOQ beside JPA for a reporting
   endpoint is legitimate and common; what is not legitimate is one of them arriving because a
   query was easier to write that way. Write the split down.

## Kotlin and JPA

Hibernate was designed against a language where classes are open and have a no-arg constructor.
Kotlin has neither by default, so the setup is two compiler plugins before it is any code.

```kotlin
plugins {
    kotlin("jvm") version "..."
    kotlin("plugin.spring") version "..."  // all-open for @Component, @Transactional, @Configuration
    kotlin("plugin.jpa") version "..."     // no-arg for @Entity, @Embeddable, @MappedSuperclass
    kotlin("plugin.allopen") version "..." // only if you also need entities themselves open
}

allOpen {
    annotation("jakarta.persistence.Entity")
    annotation("jakarta.persistence.MappedSuperclass")
    annotation("jakarta.persistence.Embeddable")
}
```

1. **`kotlin("plugin.jpa")` gives entities a synthetic no-arg constructor** for `@Entity`,
   `@Embeddable` and `@MappedSuperclass`. Without it Hibernate fails at startup with "No default
   constructor for entity", and the workaround people reach for — default values on every
   constructor parameter — is a different fix that stops working the moment one parameter cannot
   have a sensible default.
2. **`kotlin("plugin.spring")` opens `@Component`, `@Service`, `@Transactional` and
   `@Configuration` classes** so the container can subclass them for its proxies. It does not open
   `@Entity`. Entities need to be open only if you want lazy `@ManyToOne` proxies at all — declare
   that separately in `allOpen` as above, and decide it once for the project.
3. **Entities are plain classes, not `data class`.** The generated `equals`/`hashCode` compare
   every property, which on a lazy association triggers a load or throws outside the session; the
   generated `toString` recurses through a bidirectional relation until the stack ends; and `copy`
   hands you a detached twin of a managed row.
4. **`equals` is by id when the id is assigned, identity otherwise.** A `hashCode` that changes
   when the database assigns an id will lose the entity in any `HashSet` it was already in — so
   return a constant (or the class's hash) rather than the id's, and compare ids in `equals`. A
   natural business key, when one genuinely exists and never changes, is the better answer.
5. **Ids are `var id: Long? = null` with `@GeneratedValue`, or assigned before the insert.**
   Assigning client-side (`@Id val id: UUID = UUID.randomUUID()`) makes the entity valid the moment
   it is constructed, which is what makes `equals` simple and lets the domain hold an identity
   before a row exists. `lateinit var id` compiles and then throws on `equals` for a new instance.
6. **Every `@ManyToOne` and `@OneToOne` is `fetch = FetchType.LAZY`.** Their default is EAGER, so
   loading one order silently loads its customer, that customer's account, and whatever those point
   at. `@OneToMany` is lazy already; leave it that way.
7. **The read path names what it needs** — a fetch join (`join fetch`), an `@EntityGraph` on the
   query, or a projection when the caller wants three columns. Lazy is the default *because* the
   query decides, not the mapping.
8. **`spring.jpa.open-in-view=false`, always.** The default `true` keeps a session open for the
   whole HTTP request, which makes a lazy read in the serializer work — and hides every N+1 behind
   the view layer while holding a pooled connection until the response is written.
9. **The entity does not leave the service.** Outside its transaction the associations throw and
   the change tracking is gone, so a controller that returns an entity is either serializing
   proxies or keeping the session open to avoid it. Map to a DTO at the boundary (`arch-clean`).

## Exposed Shape

```kotlin
object Orders : Table("orders") {
    val id = uuid("id")
    val customerId = uuid("customer_id").index()
    val placedAt = timestamp("placed_at")
    val status = varchar("status", 32)
    override val primaryKey = PrimaryKey(id)
}

// Ktor: one Database at startup, from the same Hikari pool everything else uses.
fun Application.configureDatabase(dataSource: DataSource) {
    Database.connect(dataSource)
}
```

1. **Tables are objects, columns are properties.** `Table("orders")` for the DSL, or
   `UUIDTable`/`LongIdTable` when you want the DAO API's `Entity` classes on top. The DSL is the
   one to reach for first: it has no identity map, no dirty checking and therefore no surprises.
2. **`Database.connect(dataSource)` runs once**, at startup, over a pooled `DataSource`. The
   `Database.connect(url, driver, user, password)` overload builds a connection per transaction:
   fine in a test, where there is one, and never in a server.
3. **`transaction { }` is blocking.** It borrows a connection from the pool and holds it for the
   block, so on Ktor's event loop it is a thread you have taken out of circulation: run it inside
   `withContext(Dispatchers.IO)`, or on a virtual-thread executor.
4. **`newSuspendedTransaction(Dispatchers.IO) { }` is the suspending form**, and the one a
   `suspend` service method uses. It carries the transaction through the coroutine context, so a
   nested call joins the same transaction instead of opening a second one.
5. **A `ResultRow` does not leave its transaction.** Map to domain inside the block; a lazily
   evaluated `Query` returned from `transaction { }` executes against a closed connection.
6. **Statements are explicit** — `Orders.insert { }`, `Orders.update({ Orders.id eq id }) { }`,
   `Orders.selectAll().where { }`. Exposed writes the SQL you spelled, so it has no N+1 of its own
   and a loop that queries per row is entirely your doing.
7. **`addLogger(StdOutSqlLogger)` inside a test transaction** prints the statements; in production
   use the database's own logging.

## Transaction Boundary

**The boundary is the service method — that is `arch-layered`'s `## Transaction Boundary`, and it
does not change here.** Read it there: never on the controller, never on the repository, and on
Ktor with Exposed the same placement spelled as `newSuspendedTransaction { }` around the service
body. `arch-hexagonal` covers the variant where the core may not import the container.

What JPA adds on top of that placement:

- **`@Transactional` is a proxy, so the class must be `open`** — `kotlin("plugin.spring")` above.
  A `private` method, or one service method calling another through `this`, never reaches the
  proxy and runs with no transaction at all, silently.
- **Rollback is on unchecked exceptions only.** Kotlin has no checked exceptions, so this bites
  less often than in Java — but a `@Transactional` method that catches an exception and returns
  normally commits, and `rollbackFor` is how you say otherwise.
- **`@Transactional(readOnly = true)` on read paths.** It sets the JDBC connection read-only (which
  a replica router can use), and tells Hibernate to skip dirty-check flushing on every query.
- **The persistence context is the transaction.** Everything loaded inside is managed and
  auto-flushed on commit; there is no `save()` needed for a change to an entity you loaded, and no
  lazy read possible after the method returns.
- **`TransactionTemplate` for the programmatic case** — a boundary starting partway through a
  method, or `REQUIRES_NEW` for an audit write that must survive the rollback around it.
- **One transaction, one connection.** A method holding a second transaction on a second datasource
  takes two pool slots per request, and the deadlock that follows under load reads as a pool leak.

## N+1

The read path issues one query for the parents and then one per parent for a lazy association.
It never fails, it passes every test with three rows, and it is the single most common reason a
JVM endpoint is slow.

```properties
# application-test.properties — measure, do not read SQL by eye
spring.jpa.properties.hibernate.generate_statistics=true
spring.jpa.properties.hibernate.session.events.log.LOG_QUERIES_SLOWER_THAN_MS=50
```

1. **Count statements, do not read them.** `SessionFactory.getStatistics()` with
   `generate_statistics=true` gives `getPrepareStatementCount()` — assert it in a test around the
   read path, and the regression is caught by the build rather than by a customer.
2. **`spring.jpa.show-sql=true` is a test-only switch.** In production it writes unstructured SQL
   to stdout with no bind parameters and no timing; use the `org.hibernate.SQL` logger, or
   `datasource-proxy` / `p6spy` when you need parameters and durations.
3. **`LOG_QUERIES_SLOWER_THAN_MS` names the slow statement in production** without turning every
   statement into a log line.
4. **The fix is on the query, not the mapping.** A `join fetch`, an `@EntityGraph` on the
   repository method, or a projection. Turning the association EAGER trades one N+1 for a join on
   every read path in the application, including the ones that did not want the children.
5. **`@BatchSize(size = n)` on a collection turns N queries into N/n** — the right answer when the
   association is read on many paths and a fetch join would multiply rows.
6. **Two collection fetch joins in one query is a cartesian product.** Hibernate refuses more than
   one bag; with `Set` semantics it returns `lines × payments` rows. One collection per query.
7. **Exposed, jOOQ and Spring Data JDBC have no lazy loading and therefore no ORM N+1** — but a
   `map { findLinesFor(it.id) }` over a result set is the same bug, written out by hand, and the
   statistics test above is what catches it there too.

## Connection Pool

HikariCP is the pool Spring Boot configures by default and the one to use on Ktor as well.

1. **Small is fast.** The sizing rule is `connections ≈ cores × 2 + effective spindles`; on modern
   hardware with SSDs that lands near `cores × 2`. Start at 10, measure, and change it only with a
   number in hand.
2. **A bigger pool moves the queue, it does not remove it.** Past the point the database can
   execute in parallel, extra connections add context switching and lock contention inside the
   database — where you cannot see them — instead of a wait in your app, where you can.
3. **Sum the pools across every replica and every other client**, and keep the total safely under
   the database's `max_connections`. Eight replicas at `maximumPoolSize = 50` is 400 connections
   from one service, and Postgres's default limit is 100.
4. **`maximumPoolSize` is the only sizing knob that matters**; leave `minimumIdle` equal to it for
   a server under steady load, so a traffic spike is not also a connection storm.
5. **`connectionTimeout` (default 30s) is how long a caller waits for a slot.** Set it to what a
   request can survive — a few seconds — so exhaustion is a fast typed failure, not a pile-up.
6. **`leakDetectionThreshold` finds the connection nobody returned.** Turn it on in staging; the
   stack trace it logs names the method that held it.
7. **A pooled connection is held for the whole transaction**, so a slow HTTP call inside a
   `@Transactional` method occupies a database connection for its duration. Do the network work
   outside the boundary.

## Testing

1. **Test against the database you deploy on.** H2 in Postgres compatibility mode has different
   types, different `ON CONFLICT` behaviour, different casing rules and no extensions; the bugs it
   hides are exactly the ones that only appear in production.
2. **`@DataJpaTest` + Testcontainers is the standard slice.** Disable the embedded-database
   replacement, and let `@ServiceConnection` (Boot 3.1+) wire the URL, user and password — no
   `@DynamicPropertySource` any more:

```kotlin
@DataJpaTest
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Testcontainers
class OrderRepositoryTest(@Autowired val orders: OrderRepository) {
    companion object {
        @Container @ServiceConnection @JvmStatic
        val postgres = PostgreSQLContainer<Nothing>(DockerImageName.parse("postgres:16-alpine"))
    }
}
```

3. **`PostgreSQLContainer<Nothing>` is the Kotlin form.** The class is self-typed for Java's
   builder chaining, and `<Nothing>` is how Kotlin says "no subclass" without a raw-type warning.
4. **One container per suite, not per test.** A `@JvmStatic` `companion object` `@Container` starts
   once; a member `@Container` restarts per test method. Reuse (`withReuse(true)` plus
   `testcontainers.reuse.enable`) is the next step when local runs still hurt.
5. **The migration tool runs in the test.** That is a feature: the test proves the schema the
   migrations produce is the schema the mapping expects, which is what `ddl-auto=validate` checks
   in production (`persistence-migrations`).
6. **`@DataJpaTest` is transactional and rolls back at the end**, so nothing is flushed unless you
   ask. Call `TestEntityManager.flush()` and `clear()` before asserting a query count or a
   constraint violation — otherwise you are asserting against the first-level cache.
7. **Exposed needs no slice.** `Database.connect(container.jdbcUrl, driver = "org.postgresql.Driver",
   user = container.username, password = container.password)` in a JUnit 5 `@BeforeAll`, run the
   migrations, and the repository tests are plain JVM tests.
8. **The layer above the repository is tested with a fake port**, no database at all — what the
   boundary in `persistence-architecture` is for, and where most of the tests belong.

## Common Mistakes

1. **`data class` under `@Entity`.** The generated `equals` walks lazy associations, `toString`
   recurses through the bidirectional relation, and `copy` produces a detached duplicate that a
   later `save()` inserts as a second row. The most Kotlin-specific bug here, and it compiles.
2. **Missing `kotlin("plugin.jpa")`.** The application fails to start with "No default constructor
   for entity", and the fix that gets applied is a default value on every constructor parameter —
   which works until a non-nullable association has no sensible default, and which quietly makes
   every entity constructible in an invalid state.
3. **`hashCode` derived from a generated id.** The entity goes into a `Set` before the insert with
   one hash and is looked up after the flush with another, so `contains` returns false for an
   object the set holds. Constant hash, id-based `equals`, or a real business key.
4. **`FetchType.EAGER` left as the `@ManyToOne` default.** Every read of the child loads the
   parent, its parent, and the graph behind them; the endpoint that wanted one row selects a
   hundred, and the join is invisible in the code because nobody wrote it.
5. **`open-in-view` left at its default `true`.** Lazy reads in the serializer work, so nobody
   notices the N+1 — while the request holds a pooled connection from controller entry until the
   last byte of JSON is written, which is what exhausts the pool under load.
6. **`ddl-auto=update` in an environment with real data.** It adds what it can infer and silently
   skips what it cannot — a narrowed column, a dropped one, a changed constraint — until two
   environments have different schemas and neither matches the migration files.
7. **`@Transactional` on a private method, or on one reached by self-invocation.** The proxy is
   never entered, so there is no transaction, no rollback and no error: the writes commit
   individually and the failure is a half-applied operation nobody can reproduce.
8. **`@Transactional` on the repository.** Each call gets its own transaction, so two writes in one
   service method cannot roll back together — the reservation survives the order that failed to
   save (`arch-layered`).
9. **The entity serialized straight out of the controller.** The API contract becomes the table
   layout, a lazy field either throws or triggers a query during serialization, and renaming a
   column is a breaking API change.
10. **A pool size picked by feel.** `maximumPoolSize = 100` on eight replicas is 800 connections
    against a `max_connections` of 100; the symptom is `FATAL: sorry, too many clients already`
    from a service that looks idle.
11. **H2 standing in for Postgres in tests.** The suite is green, the deploy is not: a `text[]`
    column, a partial index, an `ON CONFLICT ... WHERE` — none behave the same, and the migration
    H2 accepted is the one that fails on deploy.
12. **`transaction { }` called from a coroutine on Ktor's event loop.** It blocks the thread for
    the whole database round trip; under concurrency the server stops accepting work while every
    metric still reads healthy. `newSuspendedTransaction(Dispatchers.IO)`, or a virtual-thread
    dispatcher (`concurrency-coroutines`).
