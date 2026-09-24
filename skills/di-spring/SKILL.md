---
name: di-spring
description: "Use when the DI is Spring's container on a Kotlin server — constructor injection, @Configuration and @Bean, scopes, profiles, conditional beans, @ConfigurationProperties with Kotlin data classes, the all-open/final plugin story, and test slices with @MockkBean."
---

# Spring DI

The `ApplicationContext` is a composition root you do not write: Spring finds the classes, reads the
annotations, and assembles the graph before `main` returns. That inverts the usual questions — not
"where do I wire this" but "which annotation makes the container see it, how long does it live, and
what does a test replace". Where the root sits among the other targets is `di-composition-root`; this
skill covers the container itself, plus the two things Kotlin changes about it: classes are final,
and a `data class` is not a bean.

> **Related skills:**
> - `di-composition-root` — the role an `ApplicationContext` fills, and what a bootstrap step may do
> - `di-koin` — the container on Ktor or http4k: `di-composition-root` → "Choosing the Container"
> - `arch-layered` — which layer each bean belongs to, and why `@Transactional` sits on the service
> - `arch-hexagonal` — why the core carries no Spring annotation and the adapters carry all of them
> - `persistence-jvm-orm` — the JPA half of the compiler-plugin story: `kotlin("plugin.jpa")` and entity design
> - `net-http-clients` — declaring a `RestClient` or `WebClient` bean, and its timeouts and interceptors
> - `error-architecture` — the `@ControllerAdvice` bean and what it maps a domain failure into

## When to Use

- A Kotlin service on Spring Boot is gaining a bean, a configuration class, a profile or a test, and
  the shape is not obvious
- User asks "why does `@Transactional` do nothing here", "`@Component` or `@Bean`", "how do I read
  config into a data class", "why is my bean not found", "how do I fake one collaborator in a slice
  test", "what does `proxyBeanMethods` cost"
- The build has just added `kotlin("plugin.spring")`, or has not and the proxies are failing
- Review finds `@Autowired lateinit var`, a `@Value` in a fifth class, a `@Component data class`, or
  a test class carrying six mock beans
- Something must exist only in one environment, and the choice is between a profile, a conditional
  and a property

Not for the persistence mapping (`persistence-jvm-orm`) and not for the layering itself
(`arch-layered`, `arch-hexagonal`) — this skill starts once Spring's container is the DI.

## Constructor Injection

**A single primary constructor with `val` parameters is the whole declaration.** Spring has used the
sole constructor without `@Autowired` since 4.3, so a Kotlin bean has no DI annotation on it beyond
its stereotype:

```kotlin
@Service
class OrderService(
    private val orders: OrderRepository,
    private val stock: StockRepository,
    private val clock: Clock,
)
```

That is not style. It buys four things at once: the class cannot be constructed half-wired, every
dependency is visible in the signature, the fields are `val` so nothing rebinds them at runtime, and
a unit test builds the class with three fakes and no container at all.

- **`@Autowired lateinit var` only where you cannot construct.** That means framework callbacks and
  base classes the container instantiates for you — and on a Kotlin server, almost nothing. Every
  other use hides a dependency and forces the test through the context.
- **Two beans of one type need a name.** `@Qualifier("primaryClock")` at both the declaration and the
  parameter, or `@Primary` on the one that should win when nobody qualifies. Prefer `@Qualifier`: a
  `@Primary` bean is chosen silently, so adding a second implementation later changes behaviour with
  no compile error.
- **An optional dependency is a nullable parameter or an `ObjectProvider<T>`.** Spring honours Kotlin
  nullability, so `private val tracer: Tracer?` resolves to `null` when no such bean exists;
  `ObjectProvider<T>` adds `getIfAvailable()` and lazy lookup for the case where the bean may appear
  later or may be many.
- **A constructor cycle is a design error the container now enforces.** Boot has rejected circular
  references by default since 2.6. `@Lazy` on one side and `spring.main.allow-circular-references`
  both make it start again and neither makes it right — the shared thing wants to be a third bean.

## Configuration

Two ways for a type to enter the graph, and the split is by ownership:

- **`@Component` and its stereotypes for classes you wrote.** `@Service` for application logic,
  `@Repository` for persistence adapters (it also translates the provider's exceptions into Spring's
  `DataAccessException` hierarchy), `@RestController` for HTTP entry points, `@Component` for the
  rest. Component scanning finds them under the `@SpringBootApplication` class's package, which is
  why that class sits at the root of the package tree and not beside the controllers.
- **`@Bean` methods in a `@Configuration` class for types you do not own.** An `ObjectMapper`, a
  `RestClient`, a `DataSource`, a `Clock`, a third-party client. You cannot annotate their classes,
  so a factory method names them:

```kotlin
@Configuration(proxyBeanMethods = false)
class ClientConfig {

    @Bean
    fun clock(): Clock = Clock.systemUTC()

    @Bean
    fun ordersClient(builder: RestClient.Builder, props: OrdersProperties): RestClient =
        builder.baseUrl(props.baseUrl).build()      // timeouts and interceptors: net-http-clients
}
```

`proxyBeanMethods` is the one knob here worth understanding. Left at `true`, Spring subclasses the
configuration class with CGLIB so that one `@Bean` method calling another returns the container's
singleton instead of a fresh object. Set to `false`, the class is used as-is: startup is faster,
there is no proxy and no subclassing requirement — and a `@Bean` method that calls a sibling method
now builds a **second** instance, silently. So the rule is mechanical: `proxyBeanMethods = false`
whenever the `@Bean` methods do not call each other, which is most of them once dependencies arrive
as method parameters, as `ordersClient` above takes `props` rather than calling `ordersProperties()`.

## Scopes

`di-composition-root`'s scopes table owns the cross-framework rows — app, screen and
request/session, and what each means before a container names it. These are the four Spring itself
declares, and how long each one actually lasts.

| Scope | Lives for | Declared as |
|---|---|---|
| singleton | the whole context — **the default, and the right answer for almost every bean** | nothing; it is what you get |
| prototype | one instance per lookup | `@Scope("prototype")` |
| request | one HTTP request (web contexts only) | `@RequestScope` |
| session | one HTTP session (web contexts only) | `@SessionScope` |

Three things about that table decide whether a graph behaves:

1. **A singleton bean must be stateless, or its state must be safe to share.** Every request thread
   touches the same instance. A `var` field on a `@Service` is a data race and a cross-request leak
   at the same time; per-request state belongs in method parameters or in a request-scoped bean.
2. **Prototype does not mean "new for every use".** A prototype injected into a singleton is resolved
   once, when the singleton is built, so the singleton then holds one instance forever. If a fresh
   instance per call is genuinely needed, inject `ObjectProvider<T>` and call `getObject()`, or take
   a factory function.
3. **Request and session scopes are proxied.** `@RequestScope` and `@SessionScope` carry
   `proxyMode = TARGET_CLASS`, so what a singleton receives is a CGLIB proxy that looks up the real
   instance per call — which is what makes injecting a request-scoped bean into a singleton legal,
   and which means the proxied class must be open (see Kotlin Specifics). Outside a request thread
   the lookup fails, so background work must be handed the values rather than the bean.

`@Lazy` is a fourth lever and not a scope: it defers construction to first use. It earns its place on
a genuinely expensive bean that most runs never touch — a report generator, a migration tool. Using
it to break a constructor cycle makes the context start and leaves the cycle, and the cycle is the
thing to fix.

## Profiles and Conditionals

Three mechanisms that look alike and answer different questions.

| Question | Mechanism |
|---|---|
| "Which environment is this?" | `@Profile("prod")` on a bean or configuration class, with `spring.profiles.active` set per deployment and `application-prod.yml` alongside it |
| "Is this feature switched on?" | `@ConditionalOnProperty(prefix = "orders", name = ["async"], havingValue = "true", matchIfMissing = false)` |
| "Did the application already define one?" | `@ConditionalOnMissingBean` — auto-configuration semantics: the application's own bean wins |
| "Is this library on the classpath?" | `@ConditionalOnClass` / `@ConditionalOnMissingClass` |

- **A profile names an environment, never a feature.** `@Profile("prod")` on a real mail sender and a
  no-op alternative is correct; `@Profile("with-cache")` is a feature flag misspelled, and the moment
  two of them must hold at once the profile string has become a combinatorial mess. Feature switches
  are `@ConditionalOnProperty`, which is one property per switch and readable in the config file.
- **`@Profile("!test")` is a smell in application code.** A bean that must not exist in tests is
  usually a bean whose test replacement should be explicit (`@TestConfiguration`), not one that
  disappears based on which profile the runner happened to activate.
- **`@ConditionalOnMissingBean` belongs in auto-configuration, not in your `@Configuration` classes.**
  It works because auto-configuration is evaluated after user beans are registered; inside an
  application's own configuration the ordering is not guaranteed, so the condition becomes a race
  between two classes nobody ordered. In a starter module you publish, it is exactly right, and it is
  what lets a consumer override your default by declaring their own bean.
- **Conditions are evaluated once, at startup.** None of these can change while the process runs. A
  switch that must flip at runtime is a value read per call, not a bean that exists or does not.

## Properties

**One typed class per configuration prefix, bound in the constructor.** A `@ConfigurationProperties`
class is where `@Value` strings stop spreading:

```kotlin
import java.time.Duration          // not kotlin.time.Duration — Spring binds the java.time one

@ConfigurationProperties(prefix = "orders")
@Validated
data class OrdersProperties(
    @field:NotBlank val baseUrl: String,
    val timeout: Duration = Duration.ofSeconds(30),
    val retries: Int = 2,
)
```

```yaml
orders:
  base-url: https://orders.internal
  timeout: 30s
```

- **Constructor binding is implicit since Boot 3** when the class has exactly one constructor, which
  a `data class` does. `@ConstructorBinding` is only needed to pick a constructor when there is more
  than one, and it goes on the constructor, not the class.
- **Register it once**: `@EnableConfigurationProperties(OrdersProperties::class)` on the configuration
  that uses it, or `@ConfigurationPropertiesScan` on the application class for all of them. A
  `@ConfigurationProperties` class is not a `@Component` and is not found by component scanning.
- **Relaxed binding maps `base-url`, `baseUrl` and `ORDERS_BASEURL` to the same property**, so the
  YAML reads as kebab-case and the Kotlin reads as camelCase with no adapter. `java.time.Duration`
  binds from `30s`, `2m`, `PT30S`; `DataSize` from `10MB`. `kotlin.time.Duration` is not a binding
  target, and a property declared with it fails to convert at startup.
- **`@Validated` plus `jakarta.validation` constraints fail the context at startup** with the property
  path in the message. Constraints go on the field via `@field:` — the annotation would otherwise
  land on the constructor parameter, where nothing reads it. This is the difference between a bad
  config failing at deploy and failing at the first request that used it.
- **`kapt("org.springframework.boot:spring-boot-configuration-processor")`** generates the metadata
  that makes these keys autocomplete in an editor. It is the one place kapt is still the answer,
  because the processor is a Java annotation processor with no KSP equivalent.
- **The properties class is a value, so a `data class` is right here** — and that is exactly the case
  where it is right. See the next section for why a `@Service` is not.

## Kotlin Specifics

Kotlin classes and members are `final` by default; Spring's proxies are subclasses. Without help,
`@Transactional` on a Kotlin `@Service` either fails to start the context, or — where the bean
implements an interface — falls back to a JDK interface proxy, and injecting the concrete class then
fails with `BeanNotOfRequiredTypeException`. Both are loud. Advice reached through the interface
still applies; what fails silently is a self-call or a `private` method (see Common Mistakes).

```kotlin
plugins {
    kotlin("jvm") version "..."
    kotlin("plugin.spring") version "..."  // all-open, keyed to Spring's own annotations
}
```

1. **`kotlin("plugin.spring")` is not optional on a Spring Boot Kotlin build.** It is the `all-open`
   plugin preconfigured for `@Component` — and therefore for `@Service`, `@Repository`,
   `@Controller`, `@RestController` and `@Configuration`, which are meta-annotated with it — plus
   `@Async`, `@Transactional`, `@Cacheable` and `@SpringBootTest`. It opens the class and its members
   so CGLIB can subclass them, and it opens nothing else. `@Entity` is a different problem with a
   different plugin: `persistence-jvm-orm` owns that half.
2. **`kotlin-reflect` must be on the runtime classpath.** Spring reads Kotlin metadata for
   nullability, default parameter values and named `@Bean` parameters; without it, defaults are
   ignored and nullable parameters stop being optional. The Boot starters pull it in for a Kotlin
   project — check it survives a dependency exclusion.
3. **`jackson-module-kotlin` for any JSON `data class`.** Jackson otherwise needs a no-arg constructor
   and ignores Kotlin nullability, so a missing JSON field becomes a `null` in a non-null property
   and the failure surfaces two layers later. Boot registers the module automatically when it is on
   the classpath.
4. **`@Bean` functions live on a top-level `@Configuration` class, not in a `companion object`.** A
   companion member is compiled onto the `Companion` class, which the container never parses, so the
   bean silently does not exist. `@JvmStatic` makes it register as a static `@Bean`, which is the
   documented form for a `BeanFactoryPostProcessor` or `BeanPostProcessor` — those must be created
   without instantiating their configuration class early. For everything else, a small separate
   `@Configuration` class holding just that bean is the clearer way to get the same isolation.
5. **`lateinit var` is for a value the framework assigns after construction**, and on a server that is
   very nearly nothing. It trades a compile-time guarantee for an
   `UninitializedPropertyAccessException` at some later call.
6. **An optional bean is a nullable parameter**, not `Optional<T>`. Java's form still works and reads
   worse; `ObjectProvider<T>` remains the answer when the dependency may be absent, plural, or must
   be looked up late.

## Testing

The context is expensive, so the question in every test is how little of it to build.

| Need | Mechanism |
|---|---|
| A unit of application logic | no Spring at all — construct the class with fakes; this is what constructor injection bought |
| One HTTP layer, no database | `@WebMvcTest(OrderController::class)` (or `@WebFluxTest`) plus `MockMvc`; everything the controller needs is mocked |
| One repository against a real schema | `@DataJpaTest` — a transactional, rolled-back test with only the persistence slice |
| Serialization of one type | `@JsonTest` |
| One HTTP client and its bindings | `@RestClientTest` with `MockRestServiceServer` |
| The whole application wired together | `@SpringBootTest`, with `webEnvironment = RANDOM_PORT` when a real port is needed |
| Replace one bean with a mock | `@MockkBean` (or `@SpykBean`) from `com.ninja-squad:springmockk`, the MockK-based pair to `@MockitoBean` — which ships in Spring Framework 6.2's `spring-test` and which Boot 3.4 adopts, deprecating its own Mockito-based `@MockBean` |
| Add a bean only tests need | a `@TestConfiguration` class, brought in with `@Import(...)`; it is not picked up by component scanning, which is the point |
| Point the context at a container or a fake server | `@ServiceConnection` on a Testcontainers field (Boot 3.1+), or `@DynamicPropertySource` for anything it does not cover |

Two facts govern how fast this suite runs. **`@SpringBootTest` loading the context is itself an
assertion** — a missing bean, an ambiguous one, an invalid property all fail there, which is the
Spring equivalent of `di-koin`'s `verify()`, and one such test is worth having. And **contexts are
cached by configuration**: every distinct set of mock beans, properties or active profiles builds a
new one. That is why a slice with two mocks is cheap and twelve `@SpringBootTest` classes with
different `@MockkBean` sets are a minutes-long suite that mostly starts Spring.

## Common Mistakes

1. **Field injection — `@Autowired lateinit var`.** The dependency vanishes from the signature, the
   object becomes legal to construct half-initialized, and the unit test has to go through the
   container to build it. Constructor injection is the default; field injection is for framework
   callbacks and needs a reason.
2. **`proxyBeanMethods` set without reading what it does.** Left `true` on every configuration class,
   it costs a CGLIB subclass per class at startup and requires the class to be open. Set `false` on a
   class whose `@Bean` methods call each other, it silently builds a second instance of a bean the
   rest of the app treats as a singleton — two connection pools, two caches. Take dependencies as
   `@Bean` method parameters, then `false` is always safe.
3. **`@Transactional` on a class the all-open plugin did not open.** Only the annotations
   `kotlin("plugin.spring")` knows are opened; a `final` helper the annotation was moved onto, or a
   `private` method, gets no proxy and no warning. Where the boundary belongs once the class is
   proxyable — and why a self-call defeats it — is `arch-layered` → "Transaction Boundary".
4. **A `data class` as a `@Component` or `@Service`.** `equals`/`hashCode` compare injected
   collaborators, `toString()` prints them into logs — credentials included — and `copy()` hands out
   a second instance of what the container calls a singleton. A `data class` models a value:
   `@ConfigurationProperties`, a DTO, a command. A bean is a plain `class`.
5. **`@MockkBean` used as the default test tool.** A test class that mocks every collaborator asserts
   that the mocks agree with each other, and every distinct mock set forks another cached context.
   Mock the boundary the slice excludes — the HTTP client, the clock — and let the rest be real.
6. **`@Value("\${orders.timeout}")` scattered across classes.** Each one is an untyped string parsed at
   the use site, spelled slightly differently in three places, with no default, no validation and no
   metadata; the Kotlin escape (`\$`) makes it worse to read. One `@ConfigurationProperties` class per
   prefix replaces all of them and fails at startup when a value is missing.
7. **A profile used as a feature flag.** `@Profile("with-retry")` cannot be switched without a
   redeploy, does not appear in the config file next to the values it changes, and multiplies with
   every other profile. `@ConditionalOnProperty` is one property, in one place.
8. **Spring annotations in the domain.** `@Service` on a use case or `@Autowired` on a core class puts
   the container on the classpath of the module that exists to be free of it. The core is plain
   Kotlin; the `@Bean` or `@Component` that names it lives in the adapter or the application module
   (`arch-hexagonal`, `arch-clean`).
