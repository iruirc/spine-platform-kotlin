---
name: net-http-clients
description: "Use when choosing and configuring an HTTP client in Kotlin — Retrofit+OkHttp, Ktor client, OkHttp alone, Spring RestClient/WebClient — and a serializer (kotlinx.serialization, Moshi, Jackson). Covers the decision by target (KMP forces Ktor), interceptors vs plugins, timeouts, connection pools, logging redaction, and test doubles per client."
---

# HTTP Clients in Kotlin

Which client a Kotlin project should hold, which serializer feeds it, and the four settings that are
wrong by default in every one of them: timeouts, the shared connection pool, header redaction in the
logs, and the double the tests replace it with. What the client is wrapped in — the API interface,
the middleware order, retry and refresh policy — is `net-architecture`, and it is the same on every
row of the table below.

> **Related skills:**
> - `net-architecture` — the boundary and the middleware order this client is configured to sit inside
> - `net-openapi` — generating the client from a spec instead of hand-writing the interface, and what still has to be configured
> - `concurrency-coroutines` — why every row here is `suspend`, and what `runBlocking` costs where it is reached for
> - `error-architecture` — mapping each client's exception family to one domain error type
> - `pkg-kmp-source-sets` — the `commonMain` constraint behind the KMP row, and where per-target engines are declared
> - `di-hilt` — providing the single client instance on Android, and the scope it belongs to
> - `di-koin` — the same single instance on KMP, Compose Desktop and Ktor
> - `di-spring` — `RestClient.Builder` and `WebClient.Builder` as beans, and the per-service instances built from them

## When to Use

- A project needs its first HTTP call and the dependency has not been picked
- User asks "Retrofit or Ktor", "does KMP change this", "kotlinx.serialization or Moshi", "why does
  Jackson blow up on my data class", "what timeouts should I set", "how do I test this without a
  server"
- A module about to be shared with another target still holds a JVM-only client
- Review finds a client constructed per call, `runBlocking` around a suspending call, or a logging
  interceptor at body level with no redaction
- Two HTTP clients have appeared in one build and nobody has said which one is leaving

Not for the layer above the client — the API interface, retry, refresh, paging, caching are all
`net-architecture`. Not for generating a client from a spec (`net-openapi`).

`references/detailed-guide.md` lies beside this file; its `## Contents` names the sections — read only the ones the table points to.

## When To Load The Reference

| Need | Reference sections |
|---|---|
| The shared payload, middleware order and `TokenStore` every client below assumes | `Shared Setup` |
| Retrofit over a configured OkHttp, with the interceptor stack | `Retrofit + OkHttp` |
| A Ktor client with timeouts, negotiation, redacting logs, retry and bearer refresh | `Ktor Client` |
| OkHttp used directly, with no typed layer over it | `OkHttp Alone` |
| A blocking outbound client in a Spring service | `Spring RestClient` |
| A reactive outbound client in a Spring service | `Spring WebClient` |
| A CLI or tool calling out with no HTTP dependency at all | `JDK HttpClient` |
| Tests against a real socket for Retrofit or OkHttp | `Retrofit + OkHttp — Test Double`, `OkHttp Alone — Test Double` |
| Tests with no socket, running on every KMP target | `Ktor Client — Test Double` |
| Tests for a Spring outbound call | `Spring RestClient — Test Double`, `Spring WebClient — Test Double` |
| Wiring a serializer into any of the above | `Serializer — kotlinx.serialization`, `Serializer — Moshi`, `Serializer — Jackson` |

## Decision by Target

| Target | Take | Because |
|---|---|---|
| Android app, no shared code planned | Retrofit + OkHttp, with `converter-kotlinx-serialization` | the mature default: typed interfaces, an interceptor model everyone on the team has seen, and `MockWebServer` for tests |
| Android app already on Ktor, or sharing code with another target soon | Ktor client on the `OkHttp` engine | one client instead of two, and the same code compiles when the module moves to `commonMain` |
| Kotlin Multiplatform, client code in `commonMain` | Ktor client — the only option | Retrofit, Moshi and OkHttp are JVM-only; engines are per target (`OkHttp` or `Android` on Android, `Darwin` on iOS and macOS, `CIO` or `Java` on JVM and desktop, `Js` on web) |
| Spring server calling another service, blocking | `RestClient` (Spring Framework 6.1+, Boot 3.2+) | the fluent successor to `RestTemplate` with none of the reactive stack; on virtual threads a blocking call is no longer the problem it was |
| Spring server calling another service, reactive | `WebClient` | needed when the caller is already reactive; it drags in `spring-webflux` even in a servlet application, which is the cost of the row |
| Non-Spring JVM server, or a Spring one that is coroutine-first throughout | Ktor client | `suspend` all the way down with no `Mono` to bridge |
| CLI or build tool | Ktor client on the `CIO` engine, or `java.net.http.HttpClient` | the JDK client costs no dependency and is enough for a handful of calls; take Ktor as soon as there are plugins worth having |
| Streaming, uploads, WebSockets or anything with no typed API to declare | OkHttp alone (or the Ktor client directly) | a typed interface over one endpoint that returns bytes buys nothing |

1. **KMP is the only forcing row.** Every other row is a preference that a team can argue with; this
   one is a compile error (`pkg-kmp-source-sets`).
2. **Retrofit is a layer over OkHttp, not an alternative to it.** Choosing Retrofit means configuring
   OkHttp — the timeouts, the pool, the interceptors and the cache are all still OkHttp's.
3. **Decide once, per build.** The choice belongs in the project guidance file next to the rest of
   the stack, because the second client always arrives as a transitive convenience.
4. **Ktor's engine is a separate decision from Ktor.** On Android the `OkHttp` engine gets the
   interceptor and cache machinery back; `CIO` is pure Kotlin and the lightest thing that works.
5. **`RestTemplate` is not a reason to stay on `RestTemplate`.** It is maintained, not developed;
   `RestClient` speaks to the same request factories and the same `MockRestServiceServer`, so the
   migration is per call site and can be partial.
6. **The JDK's `java.net.http.HttpClient` has no interceptor model.** Everything `net-architecture`
   asks for — logging, auth, retry — is hand-written around it, which is the right trade only while
   the call count is small enough to see on one screen.

## Serializer

| Serializer | Runs on | Mechanism | Take it when |
|---|---|---|---|
| `kotlinx.serialization` | every Kotlin target | a compiler plugin generates the serializer from `@Serializable`; no reflection | new Kotlin code, and mandatory in `commonMain` — the other two do not exist there |
| Moshi | JVM and Android | KSP codegen (`@JsonClass(generateAdapter = true)`) or reflection via `moshi-kotlin` | the codebase already uses it; it is Kotlin-aware about nullability and default values |
| Jackson | JVM | reflection plus modules | a Spring server, where it is the default and every starter assumes it |

1. **`ignoreUnknownKeys = true` on any wire you do not own.** The default is to fail, so the day the
   server adds a field the app stops parsing — an outage caused by a backwards-compatible change.
2. **`jackson-module-kotlin` is not optional.** Without it Jackson ignores Kotlin nullability and
   default arguments, writes `null` into a non-null `val` through reflection, and the
   `NullPointerException` lands far away in code the compiler proved safe.
3. **Moshi's codegen over its reflection.** Reflection pulls `kotlin-reflect` into the app, is slower
   to start, and the adapter errors arrive at runtime instead of at build time.
4. **One configured instance, injected.** A `Json { }`, a `Moshi` or an `ObjectMapper` built at a call
   site has different settings from the others, and the difference shows up as one endpoint that
   parses dates and one that does not.
5. **Dates and money are explicit.** Pick the wire representation (`Instant` as ISO-8601, minor units
   as `Long`) and register the module or the custom serializer once, centrally.

## Configuration per Client

```kotlin
val logging = HttpLoggingInterceptor().apply {
    level = if (BuildConfig.DEBUG) Level.BODY else Level.NONE
    redactHeader("Authorization")
    redactHeader("Cookie")
}

val http = OkHttpClient.Builder()
    .connectTimeout(10.seconds.toJavaDuration())
    .readTimeout(20.seconds.toJavaDuration())
    .callTimeout(60.seconds.toJavaDuration())
    .addInterceptor(logging)
    .addInterceptor(AuthInterceptor(tokens))
    .addInterceptor(RetryInterceptor())
    .build()
```

One chain, in the middleware order: OkHttp's `authenticator` seat runs inside its retry-and-follow-up
layer, below every application interceptor, so mixing it with an app-level retry inverts auth and
retry. `net-architecture` owns that rule; the reference has both interceptors in full.

The same chain on a Ktor client, where the layers are plugins rather than builder calls:

```kotlin
private val idempotent = setOf(HttpMethod.Get, HttpMethod.Put, HttpMethod.Delete, HttpMethod.Head)

val http = HttpClient(OkHttp) {
    install(Logging) {
        level = if (isDebug) LogLevel.BODY else LogLevel.NONE
        sanitizeHeader { it == HttpHeaders.Authorization }
    }
    install(Auth) {
        bearer {
            loadTokens { tokens.current.let { BearerTokens(it.access, it.refreshToken) } }
            refreshTokens {
                tokens.refresh(tokens.current).let { BearerTokens(it.access, it.refreshToken) }
            }
        }
    }
    install(HttpRequestRetry) {
        maxRetries = 3
        retryIf { req, res -> req.method in idempotent && res.status.value in 500..599 }
        retryOnExceptionIf { req, cause -> req.method in idempotent && cause is IOException }
        exponentialDelay()
    }
    install(HttpTimeout) {
        connectTimeoutMillis = 10_000; requestTimeoutMillis = 30_000; socketTimeoutMillis = 20_000
    }
}
```

`HttpRequestRetry` is method-blind, so both predicates are guarded: `retryOnServerErrors()` on its
own repeats every POST. `ContentNegotiation`, `defaultRequest` and the engine argument are left out
for length — see the reference for the full plugin set.

1. **Set the timeouts; the defaults are not a policy.** OkHttp ships 10 seconds each for connect, read
   and write and *no* call timeout, so a slow drip of bytes holds a request open forever — add
   `callTimeout`. The Ktor client has no client-level timeout policy until `HttpTimeout` is installed
   — whatever the engine defaults to is what applies, and that differs per engine — and its three
   knobs are `requestTimeoutMillis`, `connectTimeoutMillis` and `socketTimeoutMillis`. In Spring the
   timeouts live on the request factory or the connector, not on the builder.
2. **One `OkHttpClient` per process, one `HttpClient` per process.** The instance owns the connection
   pool, the dispatcher's threads and the response cache; building one per call throws all three away
   every time and leaks threads until the pool evicts them. A variant — a different timeout for
   uploads, an extra interceptor — comes from `newBuilder()`, which shares the pool and the cache with
   its parent. Retrofit instances over a shared client are cheap; the client is what is expensive.
3. **Close what needs closing.** A Ktor `HttpClient` holds engine resources and is `close()`d at
   shutdown; a long-lived one that is never closed in a CLI keeps the process alive.
4. **Redact before you log, not after.** `HttpLoggingInterceptor.redactHeader("Authorization")` and
   `redactHeader("Cookie")`; in Ktor, `Logging { sanitizeHeader { it == HttpHeaders.Authorization } }`
   with a `Logger` that writes through the app's own logging rather than to stdout.
5. **Bodies are a debug-only level.** `Level.BODY` and Ktor's `LogLevel.BODY` print the payload —
   tokens, addresses, order contents — into a log that on Android any app-adjacent tooling can read
   and on a server ships to an aggregator with a different retention policy than the database.
6. **URLs are not safe by default either.** A query string carrying a session id or an email is
   logged at `Level.BASIC` too; keep secrets out of query parameters and prefer `NONE` in release.
7. **Configure once, in the composition root.** The client is built where the graph is assembled
   (`di-hilt`, `di-koin`, `di-spring`) and injected everywhere else, so there is exactly one place
   where a timeout or a header policy can be wrong.

## Test Doubles

| Client | Double | Runs on | Asserts through |
|---|---|---|---|
| Retrofit + OkHttp | `MockWebServer` | JVM and Android | `takeRequest()` — path, method, headers, body |
| OkHttp alone | `MockWebServer` | JVM and Android | the same recorded request |
| Ktor client | `MockEngine` | every KMP target, no socket | the `HttpRequestData` handed to the handler |
| Spring `RestClient`, `RestTemplate` | `MockRestServiceServer` bound to the builder | JVM | `expect(requestTo(...)).andExpect(method(...))` |
| Spring `WebClient` | an `ExchangeFunction` stub on the builder, or WireMock for the whole surface | JVM | the `ClientRequest` the stub receives |

1. **The double is for the transport's own behaviour** — the URL that was built, the header that was
   added, the retry that fired. Everything above the API interface is tested against a fake of that
   interface with no client at all (`net-architecture`).
2. **`MockWebServer` is JVM-only, so it cannot live in `commonTest`.** A KMP module tests through
   `MockEngine`; that is not a preference, it is the same constraint as the client choice.
3. **A real socket is what makes `MockWebServer` worth its cost.** It exercises the converter, the
   interceptor chain and the URL builder — the parts most likely to be wrong — and it can enqueue a
   throttled or half-closed response to test the timeouts.
4. **WireMock is the honest answer for `WebClient`**, and for any client whose stubbing API fights
   back. It costs a port and some startup, and it tests the whole HTTP surface rather than one seam.

## Common Mistakes

1. **Two HTTP clients in one app.** Retrofit for the old feature and Ktor for the new one means two
   connection pools, two interceptor stacks, two log formats, two places the auth header can be
   missing, and a bug that reproduces in one half of the app. Pick the row and migrate to it.
2. **`runBlocking` around a suspending call.** It blocks the calling thread until the request
   finishes — on Android's main thread that is a frozen UI and an ANR, on a server thread it is the
   thread pool it was supposed to free. It exists for `main()`, for tests, and for blocking callbacks
   OkHttp invokes on its own threads (`Interceptor`, `Authenticator`) — nowhere else
   (`concurrency-coroutines`).
3. **Logging bodies in release.** `Level.BODY` left on ships tokens and personal data into logcat or
   the log aggregator, and the `Authorization` header goes with it unless it was redacted. Body
   logging is behind a debug check, and `redactHeader` is not optional.
4. **A new client per request.** Every call pays a fresh TCP and TLS handshake, the response cache
   never hits, and the abandoned dispatchers keep their threads until they idle out. One instance,
   `newBuilder()` for variants.
5. **Jackson without `jackson-module-kotlin`.** Non-null `val`s get `null` written into them by
   reflection, default arguments are ignored, and the failure surfaces as an NPE in code with no
   nullable type in sight.
6. **Default timeouts, or no policy at all.** A Ktor client with `HttpTimeout` never installed has no
   client-level policy and inherits whatever its engine happens to default to — different on `CIO`,
   `OkHttp` and `Darwin`. An OkHttp client with no `callTimeout` holds a spinner on screen for as long
   as the server keeps dripping bytes.
7. **A JVM-only client in a module that is about to be shared.** Retrofit and Moshi in what will
   become `commonMain` means the migration is a rewrite of every data source rather than a source-set
   move (`pkg-kmp-source-sets`).
8. **`.block()` on a `WebClient` call**, on a thread that may be one of Reactor's own — the reactive
   stack refuses it, and where it does not, one blocked event-loop thread stalls unrelated requests.
   If the caller is blocking, `RestClient` is the row.
9. **`ignoreUnknownKeys` left at its default on a third-party API.** Parsing fails on the first field
   the server adds, and the incident is filed against a release that changed nothing.
