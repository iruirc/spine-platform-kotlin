# persistence-jvm-orm — detailed guide

## Contents

- The Domain Side
- JPA — Entity and Gradle Plugins
- JPA — Repository and the Read Path
- JPA — @DataJpaTest with Testcontainers
- Exposed — Tables and DSL
- Exposed — Repository on Ktor
- Exposed — Testcontainers Test
- jOOQ — Codegen and a Typed Query
- Spring Data JDBC — Aggregate Root
- Finding an N+1 with Hibernate Statistics
- HikariCP Sizing

## The Domain Side

The domain side belongs to no engine:

<!-- compile: ktor -->
```kotlin
// :domain — nothing below this block appears in it.
import java.time.Instant

data class Order(
    val id: OrderId, val customerId: CustomerId, val placedAt: Instant,
    val status: OrderStatus, val lines: List<OrderLine>,
)

interface OrderRepository {
    fun byCustomer(customer: CustomerId): List<Order>
    fun byId(id: OrderId): Order?
    fun save(order: Order): Order
}
```

The schema is owned by Flyway or Liquibase in all four; nothing here creates a table
(`persistence-migrations`), and artifacts are named where first used.

## JPA — Entity and Gradle Plugins

```kotlin
// build.gradle.kts
plugins {
    kotlin("jvm")
    kotlin("plugin.spring")   // all-open: @Component, @Service, @Transactional, @Configuration
    kotlin("plugin.jpa")      // no-arg: @Entity, @Embeddable, @MappedSuperclass
    kotlin("plugin.allopen")
}

allOpen {
    annotation("jakarta.persistence.Entity")
    annotation("jakarta.persistence.MappedSuperclass")
    annotation("jakarta.persistence.Embeddable")
}
```

With `org.springframework.boot:spring-boot-starter-data-jpa` and `org.postgresql:postgresql` at
runtime. `plugin.jpa` synthesises the no-arg constructor Hibernate instantiates rows with;
`plugin.spring` opens container-managed classes so `@Transactional` can be proxied. `allOpen` is
separate: without it Hibernate cannot subclass an entity, so a lazy `@ManyToOne` loads eagerly.

<!-- compile: spring -->
```kotlin
import java.time.Instant
import java.util.UUID

@Entity
@Table(name = "orders")
class OrderEntity(
    @Id val id: UUID = UUID.randomUUID(),                  // assigned here, not by the database
    @Column(name = "customer_id", nullable = false) val customerId: UUID,
    @Column(name = "placed_at", nullable = false) val placedAt: Instant,
    @Enumerated(EnumType.STRING) @Column(nullable = false, length = 32) var status: OrderStatus,
) {
    @OneToMany(mappedBy = "order", cascade = [CascadeType.ALL],
        orphanRemoval = true, fetch = FetchType.LAZY)
    val lines: MutableList<OrderLineEntity> = mutableListOf()

    fun addLine(line: OrderLineEntity) {
        lines += line
        line.order = this                                  // both sides, or the FK stays null
    }

    // Assigned id: stable hash. A generated id needs a constant hash and non-null ids in equals.
    override fun equals(other: Any?) = this === other || (other is OrderEntity && id == other.id)
    override fun hashCode() = id.hashCode()
}

@Entity
@Table(name = "order_lines")
class OrderLineEntity(
    @Id val id: UUID = UUID.randomUUID(),
    @Column(nullable = false) val sku: String,
    @Column(nullable = false) val quantity: Int,
    @Column(name = "unit_price_cents", nullable = false) val unitPriceCents: Long,
) {
    @ManyToOne(fetch = FetchType.LAZY, optional = false)   // LAZY: the default is EAGER
    @JoinColumn(name = "order_id", nullable = false)
    lateinit var order: OrderEntity

    // equals/hashCode by id, exactly as above.
}
```

No `data class`, no `copy`, no `@GeneratedValue`: a `UUID` assigned in Kotlin is valid before the
insert, which keeps `equals`/`hashCode` stable across the flush. With a sequence the id is
`@GeneratedValue @Id var id: Long? = null` and the overrides change as the comment says.

```properties
spring.jpa.hibernate.ddl-auto=validate
spring.jpa.open-in-view=false
```

## JPA — Repository and the Read Path

<!-- compile: spring -->
```kotlin
import org.springframework.data.jpa.repository.EntityGraph
import org.springframework.data.jpa.repository.Query

interface OrderJpaRepository : JpaRepository<OrderEntity, UUID> {

    // One statement: parent and lines together. Without it, one query per order for the lines.
    @Query("""
        select distinct o from OrderEntity o
        left join fetch o.lines
        where o.customerId = :customerId order by o.placedAt desc
    """)
    fun findByCustomerWithLines(customerId: UUID): List<OrderEntity>

    // The declarative form of the same thing; prefer it when the query itself is derived.
    @EntityGraph(attributePaths = ["lines"])
    fun findByCustomerIdOrderByPlacedAtDesc(customerId: UUID): List<OrderEntity>
}
```

`left join fetch` with `distinct` is the workhorse; a `select new com.example.OrderSummary(...)`
constructor expression, or a projection interface, is the read that needs no entities. Two
collection fetch joins in one query are a cartesian product — so one per query, `@BatchSize(size =
50)` on the other.

<!-- compile: spring -->
```kotlin
@Repository
class JpaOrderRepository(private val jpa: OrderJpaRepository) : OrderRepository {
    // No @Transactional: it runs inside the service method's transaction (arch-layered).
    override fun byCustomer(customer: CustomerId) =
        jpa.findByCustomerWithLines(customer.value).map { it.toDomain() }
    override fun byId(id: OrderId) = jpa.findById(id.value).orElse(null)?.toDomain()
    override fun save(order: Order): Order = jpa.save(order.toEntity()).toDomain()
}

// Mapping is a pure function and is tested as one. The entity never leaves this file.
private fun OrderEntity.toDomain(): Order = Order(
    id = OrderId(id), customerId = CustomerId(customerId), placedAt = placedAt, status = status,
    lines = lines.map { OrderLine(it.sku, it.quantity, Money.ofCents(it.unitPriceCents)) },
)
```

The service above it holds the boundary — `@Transactional(readOnly = true)` on
`forCustomer`, plain `@Transactional` on `place`. `readOnly` marks the JDBC connection read-only and
lets Hibernate skip the dirty-check flush before each query: an optimisation and a statement of
intent, not a permission check.

## JPA — @DataJpaTest with Testcontainers

<!-- compile: spring-test -->
```kotlin
import java.time.Instant
import org.assertj.core.api.Assertions.assertThat
import org.springframework.boot.jpa.test.autoconfigure.TestEntityManager

@DataJpaTest
@Testcontainers
class OrderJpaRepositoryTest(
    @Autowired private val jpa: OrderJpaRepository,
    @Autowired private val em: TestEntityManager,
) {
    companion object {
        // Static: started once for the whole class. A non-static @Container restarts per test.
        @Container @ServiceConnection @JvmStatic          // wires url, user, password
        val postgres = PostgreSQLContainer("postgres:16-alpine")
    }

    @Test
    fun findByCustomerWithLines_orderWithLines_readsInOneQuery() {
        val order = OrderEntity(customerId = CUSTOMER, placedAt = Instant.now(), status = OrderStatus.NEW)
        order.addLine(OrderLineEntity(sku = "SKU-1", quantity = 2, unitPriceCents = 1_500))
        em.persist(order)
        em.flush()
        em.clear()                               // otherwise the read hits the first-level cache

        assertThat(jpa.findByCustomerWithLines(CUSTOMER)).singleElement()
            .extracting { it.lines.size }.isEqualTo(1)
    }
}
```

Four things this test does that a slice against H2 would not:

- **Real Postgres**, so types, casing, `ON CONFLICT`, partial indexes and array columns behave as
  they will in production.
- **Real migrations.** `@DataJpaTest` runs Flyway or Liquibase before the slice starts, so the test
  proves the migrated schema and the mapping agree — as `ddl-auto=validate` does at startup. The
  Boot 4 starter that brings Flyway into the slice: `persistence-migrations` → "Flyway and Liquibase".
- **`flush()` then `clear()`.** The slice wraps each test in a transaction that rolls back: without
  the flush nothing reached the database, without the clear the read never becomes SQL.
- **The container is the datasource.** `@ServiceConnection` hands its URL to the slice, whose
  default leaves a test database in place instead of swapping in an embedded one — so there is no
  `@AutoConfigureTestDatabase` and no H2 on the classpath.

For a suite, hoist that companion into a shared base class and turn on reuse (`withReuse(true)`
plus `testcontainers.reuse.enable=true`) so local runs do not pay one startup per class.

## Exposed — Tables and DSL

`org.jetbrains.exposed:exposed-core` and `exposed-jdbc`, plus `exposed-java-time` (or
`exposed-kotlin-datetime`, whose `timestamp` is a `kotlin.time.Instant`), `com.zaxxer:HikariCP`,
`org.flywaydb:flyway-core` with `flyway-database-postgresql`, and `org.postgresql:postgresql` at
runtime. Exposed 1.x lives under `org.jetbrains.exposed.v1`; `uuid()` maps `kotlin.uuid.Uuid`, so a
`java.util.UUID` column is `javaUUID()`.

<!-- compile: ktor -->
```kotlin
import org.jetbrains.exposed.v1.core.java.javaUUID
import org.jetbrains.exposed.v1.javatime.timestamp

object Orders : Table("orders") {
    val id = javaUUID("id")
    val customerId = javaUUID("customer_id").index()
    val placedAt = timestamp("placed_at")
    val status = varchar("status", 32)
    override val primaryKey = PrimaryKey(id)
}

object OrderLines : Table("order_lines") {
    val id = javaUUID("id")
    val orderId = javaUUID("order_id").references(Orders.id, onDelete = ReferenceOption.CASCADE)
    val sku = varchar("sku", 64)
    val quantity = integer("quantity")
    val unitPriceCents = long("unit_price_cents")
    override val primaryKey = PrimaryKey(id)
}
```

The `object` *describes* a table a migration created; `SchemaUtils.create(Orders)` belongs in
throwaway tests only, and `references(...)` declares the foreign key for the DSL's benefit — the
constraint is in the migration. With no lazy loading, the SQL's shape is the code's shape.

<!-- compile: ktor -->
```kotlin
import java.util.UUID

// One mapper, two queries: the same join, a different predicate.
private fun List<ResultRow>.toOrders(): List<Order> =
    groupBy { it[Orders.id] }.map { (id, rows) ->
        val head = rows.first()
        Order(
            id = OrderId(id), customerId = CustomerId(head[Orders.customerId]),
            placedAt = head[Orders.placedAt], status = OrderStatus.valueOf(head[Orders.status]),
            lines = rows.filter { it.getOrNull(OrderLines.id) != null }.map {
                OrderLine(it[OrderLines.sku], it[OrderLines.quantity],
                    Money.ofCents(it[OrderLines.unitPriceCents]))
            },
        )
    }

private fun ordersOf(customer: UUID): List<Order> =
    (Orders leftJoin OrderLines)
        .selectAll().where { Orders.customerId eq customer }
        .orderBy(Orders.placedAt to SortOrder.DESC)
        .toList().toOrders()                       // materialised inside the transaction

private fun orderById(id: UUID): Order? =
    (Orders leftJoin OrderLines)
        .selectAll().where { Orders.id eq id }
        .toList().toOrders().singleOrNull()
```

Writes are statements, not state; an update names its own predicate, nothing dirty-checks it:

<!-- compile: ktor -->
```kotlin
private fun insert(order: Order) {
    Orders.insert {
        it[id] = order.id.value; it[customerId] = order.customerId.value
        it[placedAt] = order.placedAt; it[status] = order.status.name
    }
    OrderLines.batchInsert(order.lines) { line ->
        this[OrderLines.id] = UUID.randomUUID(); this[OrderLines.orderId] = order.id.value
        this[OrderLines.sku] = line.sku; this[OrderLines.quantity] = line.quantity
        this[OrderLines.unitPriceCents] = line.price.cents
    }
}
```

Exposed also ships a DAO API (`UUIDTable` plus `class Order(id: EntityID<UUID>) : UUIDEntity(id)`)
with an identity map and lazy references — closer to JPA, same class of surprise. Start with the
DSL; take the DAO API only for a reason you can name.

## Exposed — Repository on Ktor

<!-- compile: ktor -->
```kotlin
import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import org.flywaydb.core.Flyway

fun Application.configureDatabase(config: DbConfig) {
    val pool = HikariDataSource(HikariConfig().apply {
        jdbcUrl = config.url; username = config.user; password = config.password
        maximumPoolSize = config.poolSize          // sized, not guessed — see HikariCP Sizing
        isAutoCommit = false
    })
    Flyway.configure().dataSource(pool).load().migrate()   // before any route is installed
    Database.connect(pool)          // once per process: the URL overload opens a connection per transaction
    monitor.subscribe(ApplicationStopped) { pool.close() }
}
```

<!-- compile: ktor -->
```kotlin
class ExposedOrderRepository : OrderRepository {
    // No transaction here: the caller owns the boundary (arch-layered). These run inside it.
    override fun byCustomer(customer: CustomerId): List<Order> = ordersOf(customer.value)
    override fun byId(id: OrderId): Order? = orderById(id.value)
    override fun save(order: Order): Order = order.also(::insert)
}

class OrderService(
    private val orders: OrderRepository,
    private val jdbc: CoroutineDispatcher,   // Dispatchers.IO.limitedParallelism(poolSize), made once
) {
    suspend fun place(command: PlaceOrderCommand): Order = withContext(jdbc) {
        suspendTransaction { orders.save(command.toOrder()) }
    }

    suspend fun forCustomer(customer: CustomerId): List<Order> = withContext(jdbc) {
        suspendTransaction(readOnly = true) { orders.byCustomer(customer) }
    }
}
```

- **`transaction { }` blocks the calling thread** for the whole round trip — in a Ktor handler, an
  event-loop thread taken out of circulation. Use the suspending form, inside `withContext(jdbc)`
  as above: `persistence-jvm-orm` → "Transaction Boundary".
- **A nested `suspendTransaction` joins this one.** Had `orders.save` opened its own, it would share
  `place`'s connection and roll back with it; the deprecated `newSuspendedTransaction` opened a
  second, top-level transaction whose write survived that rollback. The whole rule, savepoints
  included: `persistence-jvm-orm` → "Transaction Boundary".
- **Nothing lazily evaluated may escape the block** — a returned `Query` or `SizedIterable` executes
  against a closed connection, so call `.toList()` or `.map { }` inside.
- **Any exception rolls the block back**, checked or not — Exposed catches `Throwable` — and
  `rollback()` does it explicitly. Inside a nested block the exception's type decides what is
  undone and when: `persistence-jvm-orm` → "Transaction Boundary".

## Exposed — Testcontainers Test

No Spring context, no slice — a plain JUnit 5 test:

<!-- compile: ktor-test -->
```kotlin
import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import org.flywaydb.core.Flyway
import org.junit.jupiter.api.BeforeAll
import org.testcontainers.junit.jupiter.Container
import org.testcontainers.junit.jupiter.Testcontainers

@Testcontainers
class ExposedOrderRepositoryTest {
    companion object {
        @Container @JvmStatic
        val postgres = PostgreSQLContainer("postgres:16-alpine")

        @BeforeAll @JvmStatic
        fun connect() {
            val pool = HikariDataSource(HikariConfig().apply {
                jdbcUrl = postgres.jdbcUrl; username = postgres.username
                password = postgres.password
            })
            Flyway.configure().dataSource(pool).load().migrate()   // the real schema, not a DSL one
            Database.connect(pool)
        }
    }

    private val repository = ExposedOrderRepository()

    @Test
    fun save_orderWithLines_byIdReturnsLines() = transaction {
        addLogger(StdOutSqlLogger)                 // test-only: prints the statements
        val order = anOrder(lines = 2)
        repository.save(order)
        assertEquals(2, repository.byId(order.id)?.lines?.size)
        rollback()                                 // leave the database as it was found
    }
}
```

Each test opens its own `transaction { }` and ends with `rollback()` — the isolation `@DataJpaTest`
gets from Spring. Truncating tables in an `@AfterEach` is the fallback once the code commits.

## jOOQ — Codegen and a Typed Query

jOOQ generates Kotlin from the database, so codegen runs *after* the migrations, against a schema a
migration tool produced — a Testcontainers instance in the build, or a dedicated schema database.
Generating from a hand-maintained DDL file is how generated code and deployed schema drift apart.
The Gradle plugin is `org.jooq:jooq-codegen-gradle` (jOOQ 3.19+; `nu.studer.jooq` before that), with
`generator.name = "org.jooq.codegen.KotlinGenerator"`, the migrated database's JDBC URL and a
`target.packageName`.

```kotlin
class JooqOrderRepository(private val dsl: DSLContext) : OrderRepository {
    // One statement, one round trip: the lines arrive as a nested collection, typed.
    override fun byCustomer(customer: CustomerId): List<Order> =
        dsl.select(
            ORDERS.ID, ORDERS.PLACED_AT, ORDERS.STATUS,
            multiset(
                select(ORDER_LINES.SKU, ORDER_LINES.QUANTITY, ORDER_LINES.UNIT_PRICE_CENTS)
                    .from(ORDER_LINES).where(ORDER_LINES.ORDER_ID.eq(ORDERS.ID)),
            ).convertFrom { rows ->
                rows.map { OrderLine(it.value1(), it.value2(), Money.ofCents(it.value3())) }
            },
        )
            .from(ORDERS).where(ORDERS.CUSTOMER_ID.eq(customer.value))
            .orderBy(ORDERS.PLACED_AT.desc())
            .fetch { r ->
                Order(
                    id = OrderId(r.value1()),
                    customerId = customer,
                    placedAt = r.value2(),
                    status = OrderStatus.valueOf(r.value3()),
                    lines = r.value4(),
                )
            }
}
```

A renamed column is now a compile error, and `MULTISET` gives the nested read JPA needed a fetch
join for. `spring-boot-starter-jooq` provides the `DSLContext` and enlists it in the ambient
transaction, so jOOQ can sit beside JPA for the queries JPQL cannot express.

## Spring Data JDBC — Aggregate Root

One repository per aggregate root, no session, no lazy loading, no dirty checking: `save()` writes
the root and its children, and deletes the ones that are gone.

<!-- compile: spring-test -->
```kotlin
import java.time.Instant
import java.util.UUID
import org.springframework.data.annotation.Id
import org.springframework.data.annotation.Version
import org.springframework.data.jdbc.repository.query.Query
import org.springframework.data.relational.core.mapping.MappedCollection
import org.springframework.data.relational.core.mapping.Table

@Table("orders")
data class OrderRecord(                     // data class is fine here: there are no proxies
    @Id val id: UUID,
    val customerId: UUID, val placedAt: Instant, val status: String,
    @MappedCollection(idColumn = "order_id", keyColumn = "position")
    val lines: List<OrderLineRecord> = emptyList(),
    @Version val version: Long? = null,     // null marks the assigned id as new: save() inserts
)

@Table("order_lines")
data class OrderLineRecord(val sku: String, val quantity: Int, val unitPriceCents: Long)

interface OrderRecordRepository : CrudRepository<OrderRecord, UUID> {
    @Query("select * from orders where customer_id = :customerId order by placed_at desc")
    fun findByCustomer(customerId: UUID): List<OrderRecord>
}
```

- **The child has no back-reference.** `@MappedCollection(idColumn = ...)` names the FK column;
  `keyColumn` makes the list ordered and requires that column in the schema.
- **`save()` on an existing aggregate deletes and re-inserts the children** — the root owns them.
- **A client-assigned `@Id` reads as an existing row.** Spring Data infers "new" from a null id, so
  `save()` of a fresh aggregate issues an `UPDATE` that matches nothing — and without a version
  nothing checks the count, so the order is never written. A `@Version` that is null until the
  first save decides "new" instead and adds optimistic locking (the migration adds its column);
  `Persistable.isNew`, or `JdbcAggregateTemplate.insert`, are the alternatives.
- **References across aggregates are ids** — `AggregateReference<Customer, UUID>`, never a
  `Customer` field. That constraint is the reason to be here.

## Finding an N+1 with Hibernate Statistics

The read path returns ten orders and issues eleven queries. Nothing fails; the endpoint is slow at a
hundred rows and unusable at a thousand.

<!-- compile: spring-test -->
```kotlin
import org.hibernate.SessionFactory
import org.springframework.test.context.TestPropertySource

@DataJpaTest
@Testcontainers
@TestPropertySource(properties = ["spring.jpa.properties.hibernate.generate_statistics=true"])
class OrderReadPathQueryCountTest(
    @Autowired private val jpa: OrderJpaRepository,
    @Autowired private val em: TestEntityManager,
) {
    companion object {
        @Container @ServiceConnection @JvmStatic
        val postgres = PostgreSQLContainer("postgres:16-alpine")
    }

    @Test
    fun findByCustomerWithLines_tenOrdersWithLines_preparesOneStatement() {
        repeat(10) { n ->                        // an empty table costs one statement either way
            val order = OrderEntity(customerId = CUSTOMER, placedAt = Instant.now(), status = OrderStatus.NEW)
            order.addLine(OrderLineEntity(sku = "SKU-$n", quantity = 1, unitPriceCents = 100))
            em.persist(order)
        }
        em.flush()
        em.clear()
        val stats = em.entityManager.entityManagerFactory.unwrap(SessionFactory::class.java).statistics
        stats.clear()
        jpa.findByCustomerWithLines(CUSTOMER).forEach { it.lines.size }   // touch the association
        assertThat(stats.prepareStatementCount).isEqualTo(1)
    }
}
```

Point the same test at a derived query that fetches nothing —
`fun findByCustomerId(customerId: UUID): List<OrderEntity>` on the repository — and it fails with
11: one statement for the orders and one per order for its lines. The number is a fact checked by
the build, not a judgement about SQL somebody scrolled past. Against Exposed or jOOQ the same test
counts through a `datasource-proxy` wrapper, there being no `SessionFactory` to ask. In production
the two settings that matter are `spring.jpa.properties.hibernate.log_slow_query=50`, which names
the slow statement, and the `org.hibernate.SQL` logger left at `INFO` so nothing writes SQL to
stdout per request.

## HikariCP Sizing

```yaml
spring:
  datasource:
    hikari:
      maximum-pool-size: 10          # cores × 2 + effective spindles; start here, then measure
      minimum-idle: 10               # equal to max: no connection storm on a traffic spike
      connection-timeout: 3000       # ms a caller waits for a slot before failing fast
      max-lifetime: 1800000          # under the database's and any proxy's idle timeouts
      leak-detection-threshold: 20000  # staging: logs the stack that held a connection
```

The arithmetic that matters is the total, not one pool's. Eight replicas × 10, plus a worker's pool,
plus migrations on deploy, against a Postgres `max_connections` of 100 — which is why a service that
looks idle reports `FATAL: sorry, too many clients already` during a rolling deploy, when old and
new pods hold pools at once. Keep the total under the limit with headroom for a deploy, or put
PgBouncer in front and size against it.

Two sizing mistakes share a symptom and have opposite fixes: too small queues callers in
`connectionTimeout`, too large queues them inside the database. Measure
`hikaricp.connections.pending` and `hikaricp.connections.usage` before changing the number.
