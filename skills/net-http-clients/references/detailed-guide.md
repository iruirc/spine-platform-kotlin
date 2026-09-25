# net-http-clients — detailed guide

## Contents

- Shared Setup
- Retrofit + OkHttp
- Retrofit + OkHttp — Test Double
- Ktor Client
- Ktor Client — Test Double
- OkHttp Alone
- OkHttp Alone — Test Double
- Spring RestClient
- Spring RestClient — Test Double
- Spring WebClient
- Spring WebClient — Test Double
- JDK HttpClient
- Serializer — kotlinx.serialization
- Serializer — Moshi
- Serializer — Jackson

## Shared Setup

The payload every client shares, behind the `OrdersApi` boundary `net-architecture` declares:

<!-- compile: net -->
```kotlin
@Serializable
data class OrderDto(val id: String, val total: Long, val currency: String)

@Serializable
data class Page<T>(val items: List<T>, val nextCursor: String? = null)
```

The middleware order each configuration follows — logging outside auth, auth outside retry, timeout
innermost — is `net-architecture`'s, and so is the `TokenStore` the OkHttp `AuthInterceptor` calls:
one single-flight store exposing `current: Token` and `suspend fun refresh(seen: Token): Token`. The
Ktor client keeps none; its bearer provider is the store.
Dependencies are written as version-catalog aliases.

## Retrofit + OkHttp

`libs.retrofit`, `libs.retrofit.kotlinx.serialization`, `libs.okhttp`, `libs.okhttp.logging`.

<!-- compile: net -->
```kotlin
import java.io.File
import java.time.Duration
import kotlin.random.Random
import okhttp3.logging.HttpLoggingInterceptor
import okhttp3.logging.HttpLoggingInterceptor.Level
import retrofit2.http.Field
import retrofit2.http.FormUrlEncoded

val appJson = Json { ignoreUnknownKeys = true; explicitNulls = false }

private val logging = HttpLoggingInterceptor().apply {
    level = if (BuildConfig.DEBUG) Level.BODY else Level.NONE
    redactHeader("Authorization")
    redactHeader("Cookie")
}

private val IDEMPOTENT = setOf("GET", "HEAD", "PUT", "DELETE")
private val RETRYABLE = setOf(408, 429, 502, 503, 504)

interface AuthApi {
    @FormUrlEncoded
    @POST("auth/refresh")
    suspend fun refresh(@Field("refresh_token") refreshToken: String): Token
}

// Row 2 as an application interceptor: an Authenticator would run below RetryInterceptor.
private class AuthInterceptor(private val tokens: TokenStore) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val seen = tokens.current
        val first = chain.proceed(chain.request().withBearer(seen))
        if (first.code != 401) return first
        val fresh = try {
            runBlocking { tokens.refresh(seen) }
        } catch (e: Exception) {
            if (e is HttpException && (e.code() == 400 || e.code() == 401)) return first
            first.close()
            throw e as? IOException ?: IOException("token refresh failed", e)
        }
        first.close()
        return chain.proceed(chain.request().withBearer(fresh))
    }
}

private fun Request.withBearer(token: Token) =
    newBuilder().header("Authorization", "Bearer ${token.access}").build()

// Row 3. Idempotent methods only; a POST qualifies only by carrying an idempotency key.
private class RetryInterceptor(private val max: Int = 3) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val safe = request.method in IDEMPOTENT || request.header("Idempotency-Key") != null
        var attempt = 0
        while (true) {
            val response = chain.proceed(request)
            if (!safe || response.code !in RETRYABLE || ++attempt >= max) return response
            if (chain.call().isCanceled()) return response
            response.close()
            Thread.sleep(Random.nextLong(minOf(4_000L, 200L shl attempt)))
        }
    }
}

private val base = OkHttpClient.Builder()
    .connectTimeout(Duration.ofSeconds(10))
    .readTimeout(Duration.ofSeconds(20))
    .callTimeout(Duration.ofSeconds(60))
    .build()

// Its own Dispatcher: queued on `http`'s, the refresh would wait for the threads waiting on it.
private val refreshHttp = base.newBuilder().dispatcher(Dispatcher()).build()

private val tokens = TokenStore(
    appScope,
    Retrofit.Builder()
        .baseUrl("https://api.example.com/")
        .client(refreshHttp)
        .addConverterFactory(appJson.asConverterFactory("application/json".toMediaType()))
        .build()
        .create<AuthApi>(),
)

val http: OkHttpClient = base.newBuilder()
    .addInterceptor(logging)
    .addInterceptor(AuthInterceptor(tokens))
    .addInterceptor(RetryInterceptor())
    .cache(Cache(File(cacheDir, "http"), 20L * 1024 * 1024))
    .build()

val retrofit: Retrofit = Retrofit.Builder()
    .baseUrl("https://api.example.com/")
    .client(http)
    .addConverterFactory(appJson.asConverterFactory("application/json".toMediaType()))
    .build()

interface OrdersService {
    @GET("orders")
    suspend fun orders(@Query("cursor") cursor: String?): Page<OrderDto>

    @POST("orders")
    suspend fun place(@Body draft: OrderDraftDto, @Header("Idempotency-Key") key: String): OrderDto
}

val service: OrdersService = retrofit.create()
```

- **Pick one seat for row 2.** OkHttp's `authenticator` is the tempting one — called on a 401 with
  the failed response, with `Response.priorResponse` to bound the loop — but it runs inside
  `RetryAndFollowUpInterceptor`, below every application interceptor, so pairing it with an
  `addInterceptor(RetryInterceptor())` puts retry *outside* auth. Either auth refreshes itself as an
  application interceptor, as above, or OkHttp's own follow-up layer is the whole of row 3.
- `runBlocking` in `AuthInterceptor` holds one of `http`'s dispatcher threads until the refresh
  returns, and it is safe on two conditions, both in the sample. The refresh runs on `refreshHttp`,
  whose `Dispatcher` is its own: queued on `http`'s, it would wait behind the calls waiting for it,
  and five parallel 401s to one host — the dispatcher's per-host limit — never complete, the refresh
  included. And a failed refresh never leaves as anything but a response or an `IOException`: an
  `HttpException` or a `SerializationException` thrown from `intercept` escapes OkHttp's callback as
  an uncaught exception on the dispatcher thread, which on Android ends the process. A refresh the
  server refuses (400 or 401) returns the original 401, so the caller signs out
  (`net-architecture` → "Auth Refresh"); only a transport or server failure becomes the `IOException`.
- Blocking an OkHttp dispatcher thread, never the caller's, is what makes that `runBlocking` and the
  `Thread.sleep` in `RetryInterceptor` acceptable at all — the exception behind the mistake in
  `SKILL.md`, which is about call sites.
- `RetryInterceptor` is the minimum: honour `Retry-After` when the response carries one. Its
  cancellation check is `chain.call().isCanceled()` — `Call.cancel()` closes the socket but never
  interrupts the thread, so `Thread.interrupted()` stays `false`.
- A `suspend` method returning `Page<OrderDto>` throws `retrofit2.HttpException` on a non-2xx;
  declare `Response<Page<OrderDto>>` when the status or a header is part of the answer (a 304, a
  `Location`). Either way the service maps nothing: `net-architecture` → "Core Shape".
- `baseUrl` must end in `/` and a `@GET` path must not begin with one, or resolution drops a segment.
  Retrofit instances are cheap; share one `OkHttpClient` and use `newBuilder()` for variants.

## Retrofit + OkHttp — Test Double

<!-- compile: net-test -->
```kotlin
class OrdersServiceTest {
    private val server = MockWebServer()
    private lateinit var service: OrdersService

    @BeforeEach
    fun start() {
        server.start()
        service = Retrofit.Builder()
            .baseUrl(server.url("/"))
            .client(OkHttpClient())
            .addConverterFactory(appJson.asConverterFactory("application/json".toMediaType()))
            .build()
            .create()
    }

    @AfterEach
    fun stop() = server.close()

    @Test
    fun orders_cursorGiven_sendsItAndParsesPage() = runTest {
        server.enqueue(
            MockResponse.Builder()
                .code(200)
                .setHeader("Content-Type", "application/json")
                .body("""{"items":[{"id":"o1","total":1250,"currency":"EUR"}],"nextCursor":"c2"}""")
                .build()
        )

        val page = service.orders(cursor = "c1")

        val sent = server.takeRequest()
        assertEquals("GET", sent.method)
        assertEquals("/orders?cursor=c1", sent.target)
        assertEquals("c2", page.nextCursor)
        assertEquals("o1", page.items.single().id)
    }
}
```

- `takeRequest()` is the assertion surface — path, method, headers and body exactly as they went out,
  and the only way to prove an interceptor added the header it was supposed to.
- `bodyDelay` and `throttleBody` are how the timeouts get tested; a stub that answers instantly
  proves nothing about the four durations set on the client.
- This is OkHttp 5's `mockwebserver3` (`libs.okhttp.mockwebserver`): responses come from
  `MockResponse.Builder`, and the server is `close()`d. The client here is bare because the subject
  is the Retrofit interface; to test the interceptor stack, build the real one against
  `server.url("/")`.

## Ktor Client

`libs.ktor.client.core`, one engine per target (`libs.ktor.client.okhttp`, `.darwin`, `.cio`, `.js`),
plus `content.negotiation`, `serialization.kotlinx.json`, `auth` and `logging`.

<!-- compile: ktor -->
```kotlin
import io.ktor.client.*
import io.ktor.client.call.*
import io.ktor.client.engine.*
import io.ktor.client.plugins.*
import io.ktor.client.plugins.auth.*
import io.ktor.client.plugins.auth.providers.*
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.client.plugins.logging.*
import io.ktor.client.request.*
import java.io.IOException
import kotlinx.serialization.json.Json

val appJson = Json { ignoreUnknownKeys = true; explicitNulls = false }

fun ordersHttpClient(engine: HttpClientEngine, session: SessionStorage, isDebug: Boolean) =
    HttpClient(engine) {
        expectSuccess = true
        defaultRequest {
            url("https://api.example.com/")
            contentType(ContentType.Application.Json)
        }
        install(ContentNegotiation) { json(appJson) }
        install(Logging) {
            logger = object : Logger { override fun log(message: String) = appLog.debug(message) }
            level = if (isDebug) LogLevel.BODY else LogLevel.NONE
            sanitizeHeader { header -> header == HttpHeaders.Authorization }
        }
        // Installed before HttpRequestRetry: the outer of the two, so a refreshed
        // token is what the retries below it carry.
        install(Auth) {
            bearer {
                loadTokens { session.load() }
                refreshTokens {
                    val refresh = oldTokens?.refreshToken ?: return@refreshTokens null
                    val response = client.post("auth/refresh") {
                        markAsRefreshTokenRequest()
                        expectSuccess = false
                        setBody(RefreshRequest(refresh))
                    }
                    if (!response.status.isSuccess()) return@refreshTokens null
                    response.body<TokenPair>().let { BearerTokens(it.access, it.refresh) }
                        .also { session.save(it) }
                }
                sendWithoutRequest { request -> request.url.host == "api.example.com" }
            }
        }
        install(HttpRequestRetry) {
            val idempotent = setOf(HttpMethod.Get, HttpMethod.Put, HttpMethod.Delete, HttpMethod.Head)
            val retryable = setOf(408, 429, 502, 503, 504)
            maxRetries = 3
            retryIf { request, response ->
                request.method in idempotent && response.status.value in retryable
            }
            retryOnExceptionIf { request, cause ->
                request.method in idempotent && cause is IOException
            }
            exponentialDelay(base = 2.0, maxDelayMs = 4_000)
        }
        install(HttpTimeout) {
            connectTimeoutMillis = 10_000
            requestTimeoutMillis = 30_000
            socketTimeoutMillis = 20_000
        }
    }

class KtorOrdersApi(private val http: HttpClient) : OrdersApi {
    override suspend fun orders(cursor: String?): Page<OrderDto> =
        http.get("orders") { cursor?.let { parameter("cursor", it) } }.body()

    override suspend fun order(id: String): OrderDto = http.get("orders/$id").body()

    override suspend fun place(draft: OrderDraftDto, idempotencyKey: String): OrderDto =
        http.post("orders") {
            header("Idempotency-Key", idempotencyKey)
            setBody(draft)
        }.body()
}
```

- The bearer block follows `net-architecture` → "Auth Refresh". `expectSuccess = false` on the
  refresh call turns a rejected refresh into `null`, so the caller sees the original 401 rather than
  an exception thrown from inside the plugin.
- **`HttpRequestRetry` is method-blind.** `retryOnServerErrors()` on its own repeats every request,
  `place()` included, on every 5xx — `net-architecture`'s first mistake, installed by default. Both
  predicates are therefore guarded on the method, and the statuses are `net-architecture` → "Retry".
  `place()` carries an `Idempotency-Key` so that a repeat *is* safe once the server honours it; widen
  the predicate to include that header only after it does.
- `sendWithoutRequest` defaults to `true`: the bearer header goes up front on every request, to every
  host the client calls. The predicate keeps the token on the API's own host.
- `expectSuccess = true` turns a non-2xx into `ClientRequestException` / `ServerResponseException`,
  which `KtorOrdersApi` lets out for the repository to map; without it `body()` parses the error page
  and the failure names the serializer, not the status.
- Installed after `HttpRequestRetry`, `HttpTimeout` bounds each attempt; installed before it, one
  budget covers them all. Per-call overrides go in the request builder's `timeout { }` block.
- One `HttpClient` per process, `close()`d at shutdown; the engine is its only per-target argument,
  which is why `ordersHttpClient` takes it (`pkg-kmp-source-sets`).

## Ktor Client — Test Double

```kotlin
class KtorOrdersApiTest {
    private fun api(handler: MockRequestHandler): Pair<KtorOrdersApi, MockEngine> {
        val engine = MockEngine(handler)
        val client = HttpClient(engine) {
            expectSuccess = true
            defaultRequest { url("https://api.example.com/") }
            install(ContentNegotiation) { json(appJson) }
        }
        return KtorOrdersApi(client) to engine
    }

    @Test
    fun orders_cursorGiven_sendsItAndParsesPage() = runTest {
        val (api, engine) = api {
            respond(
                content = """{"items":[{"id":"o1","total":1250,"currency":"EUR"}],"nextCursor":"c2"}""",
                status = HttpStatusCode.OK,
                headers = headersOf(HttpHeaders.ContentType, "application/json"),
            )
        }

        val page = api.orders(cursor = "c1")

        val sent = engine.requestHistory.single()
        assertEquals(HttpMethod.Get, sent.method)
        assertEquals("c1", sent.url.parameters["cursor"])
        assertEquals("c2", page.nextCursor)
    }
}
```

- `MockEngine` opens no socket, so this runs in `commonTest` on every target — the reason it exists.
  On the JVM alone, `MockWebServer` tests more.
- `engine.requestHistory` records every attempt: the place to assert that a retry happened, or that
  it did not happen on a `POST`.
- Plugin behaviour is configuration: a double built without `HttpRequestRetry` or `Auth` proves
  nothing about the client that ships with them.
- `MockEngine { }` also takes a queue of responses via `addHandler`, one per call, when the sequence
  matters more than the request.

## OkHttp Alone

For streaming, uploads and anything with no typed API worth declaring. `libs.okhttp` and
`libs.okhttp.coroutines`, plus `libs.okio` where the body is written straight to disk.

<!-- compile: net -->
```kotlin
import java.io.File
import java.time.Duration
import okhttp3.coroutines.executeAsync

val streaming = http.newBuilder()
    .readTimeout(Duration.ZERO)
    .callTimeout(Duration.ZERO)
    .build()

suspend fun download(url: String, into: File, client: OkHttpClient = streaming) {
    val request = Request.Builder().url(url).build()
    client.newCall(request).executeAsync().use { response ->
        if (!response.isSuccessful) throw HttpStatusException(response.code)
        withContext(Dispatchers.IO) {
            response.body.byteStream().use { source ->
                into.outputStream().use { sink -> source.copyTo(sink) }
            }
        }
    }
}
```

- `executeAsync()` is what makes the call structured: it cancels the `Call` when the coroutine is
  cancelled, and closes a `Response` that arrives after the cancellation. A hand-written
  `suspendCancellableCoroutine` over `enqueue` has to do both, and the second is the one it forgets —
  a leaked body holds a connection out of the pool.
- Only the body copy blocks, so only it moves to `Dispatchers.IO`; `executeAsync()` suspends.
- `newBuilder()` shares the pool, the dispatcher and the cache with its parent; a second
  `OkHttpClient.Builder()` shares nothing — the per-request-client mistake in slow motion.
- `Response` and its body are `Closeable` even when the body is not read: `use`, every time, or a
  leaked body holds a connection out of the pool forever.
- Both time limits are cleared on the streaming variant, not just the read timeout: `callTimeout`
  is inherited by `newBuilder()` and would cut a large file at sixty seconds regardless.

## OkHttp Alone — Test Double

<!-- compile: net-test -->
```kotlin
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import okhttp3.Call
import okhttp3.EventListener

class DownloadTest {
    private val server = MockWebServer()
    private val cancelled = CountDownLatch(1)
    private val watched = streaming.newBuilder()
        .eventListener(object : EventListener() {
            override fun canceled(call: Call) = cancelled.countDown()
        })
        .build()

    @AfterEach
    fun stop() = server.close()

    @Test
    fun download_scopeCancelled_cancelsOkHttpCall() = runBlocking {
        server.start()
        server.enqueue(MockResponse.Builder().body("payload").headersDelay(10, TimeUnit.SECONDS).build())
        val into = File.createTempFile("download", null)

        val job = launch(Dispatchers.IO) { download(server.url("/file").toString(), into, watched) }
        assertNotNull(server.takeRequest(5, TimeUnit.SECONDS))
        job.cancelAndJoin()

        assertTrue(cancelled.await(5, TimeUnit.SECONDS), "the call was never cancelled")
    }
}
```

- The latch is the assertion, and `job.isCancelled` is not: a cancelled job says nothing about the
  socket, and a bridge that never calls `Call.cancel()` cancels the coroutine while OkHttp keeps
  reading. `EventListener.canceled` fires only if `Call.cancel()` was actually reached.
- `takeRequest` before the cancellation is what makes the test deterministic — cancel a job whose
  body has not run yet and the assertion passes for the wrong reason.
- `launch(Dispatchers.IO)`, not a bare `launch`: `runBlocking`'s event loop is one thread, and
  `takeRequest` blocks it, so a child queued on that same dispatcher would never start and the
  `assertNotNull` above would fail before anything was cancelled.
- `headersDelay`, not `bodyDelay`: the call has to still be suspended in `executeAsync()` when the
  cancellation lands. Once the body copy has started, it is blocking I/O and cancellation no longer
  reaches the socket through this bridge.
- `runBlocking`, not `runTest`: a real socket and a latch need real time, not virtual time.

## Spring RestClient

`spring-boot-starter-restclient`: Spring Framework's `RestClient` and the `RestClient.Builder` bean
Boot configures. Blocking, and on virtual threads that is no longer a reason to reach for the
reactive stack.

<!-- compile: spring -->
```kotlin
import java.time.Duration
import java.util.Optional
import org.springframework.boot.http.client.ClientHttpRequestFactoryBuilder
import org.springframework.boot.http.client.HttpClientSettings
import org.springframework.core.ParameterizedTypeReference
import org.springframework.web.client.RestClient

private val RETRYABLE = setOf(408, 429, 502, 503, 504)

// The test builds its client here too, so it asserts the interceptor production installs.
fun configuredOrdersClient(builder: RestClient.Builder, props: OrdersProperties): RestClient =
    builder
        .baseUrl(props.baseUrl)
        .requestInterceptor { request, body, execution ->
            request.headers.setBearerAuth(props.token)
            execution.execute(request, body)
        }
        .defaultStatusHandler({ it.value() in RETRYABLE }) { _, response ->
            throw RetryableHttpException(response.statusCode.value())
        }
        .build()

@Configuration
class OrdersClientConfig {
    @Bean
    fun ordersRestClient(
        builder: RestClient.Builder,
        factories: ClientHttpRequestFactoryBuilder<*>,
        settings: HttpClientSettings,
        props: OrdersProperties,
    ): RestClient {
        val timeouts = settings.withTimeouts(Duration.ofSeconds(10), Duration.ofSeconds(20))
        return configuredOrdersClient(builder.requestFactory(factories.build(timeouts)), props)
    }
}

@Service
class OrdersClient(private val rest: RestClient) {
    fun orders(cursor: String?): Page<OrderDto> =
        rest.get()
            .uri { it.path("/orders").queryParamIfPresent("cursor", Optional.ofNullable(cursor)).build() }
            .retrieve()
            .body(object : ParameterizedTypeReference<Page<OrderDto>>() {})!!
}
```

- Inject the `RestClient.Builder` bean rather than calling `RestClient.create()`: Boot has already
  applied its customizers, the observation registry and the message converters to it.
- Per-service timeouts go through Boot's own factory: `ClientHttpRequestFactoryBuilder` and
  `HttpClientSettings` carry the detected HTTP library and every `spring.http.clients.*` setting, and
  `withTimeouts` changes only the two durations. A hand-built `SimpleClientHttpRequestFactory` drops
  all of that, and on `HttpURLConnection` a `PATCH` fails with `ProtocolException`.
- One `RestClient` per remote service, each with its own base URL and timeouts; a shared one with
  absolute URLs at call sites has nowhere left to set a per-service budget.
- `defaultStatusHandler` is where a retryable status (`net-architecture` → "Retry") becomes the
  exception the retry layer reads; every other non-2xx keeps the default `RestClientResponseException`,
  and both leave `OrdersClient` for the repository to map. And this blocks: call it in
  `withContext(Dispatchers.IO)`, or run on virtual threads.

## Spring RestClient — Test Double

<!-- compile: spring-test -->
```kotlin
import org.junit.jupiter.api.Assertions.assertEquals
import org.springframework.http.HttpMethod
import org.springframework.http.MediaType
import org.springframework.test.web.client.MockRestServiceServer
import org.springframework.test.web.client.match.MockRestRequestMatchers.header
import org.springframework.test.web.client.match.MockRestRequestMatchers.method
import org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo
import org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess
import org.springframework.web.client.RestClient

class OrdersClientTest {
    private val props = OrdersProperties(baseUrl = "https://api.example.com", token = "test-token")
    private val builder = RestClient.builder()
    private val server = MockRestServiceServer.bindTo(builder).build()
    private val client = OrdersClient(configuredOrdersClient(builder, props))

    @Test
    fun orders_cursorGiven_sendsItAndParsesPage() {
        server.expect(requestTo("https://api.example.com/orders?cursor=c1"))
            .andExpect(method(HttpMethod.GET))
            .andExpect(header("Authorization", "Bearer test-token"))
            .andRespond(withSuccess("""{"items":[],"nextCursor":"c2"}""", MediaType.APPLICATION_JSON))

        assertEquals("c2", client.orders("c1").nextCursor)
        server.verify()
    }
}
```

- `bindTo` takes the same builder the client is built from and must be called before `build()`; bound
  to a different builder, the test passes while asserting nothing.
- `bindTo` installs its own request factory, so a configuration function that sets one afterwards
  sends the test to the real host. Hence the factory is set in the `@Bean` method, and
  `configuredOrdersClient` leaves it alone. A test that asserts a header the production interceptor
  adds has to run through that interceptor.
- `server.verify()` turns an unmet `expect` into a failure; without it, a client that made no call at
  all is green.
- The same class doubles `RestTemplate` — the other half of why migrating to `RestClient` is cheap.

## Spring WebClient

`spring-boot-starter-webclient`, which brings the Reactor Netty connector. Take it when the caller is
already reactive; it pulls the reactive stack into a servlet application otherwise.

<!-- compile: spring -->
```kotlin
import io.netty.channel.ChannelOption
import java.time.Duration
import java.util.Optional
import org.springframework.http.client.reactive.ReactorClientHttpConnector
import org.springframework.web.reactive.function.client.ClientRequest
import org.springframework.web.reactive.function.client.ExchangeFilterFunction
import org.springframework.web.reactive.function.client.WebClient
import org.springframework.web.reactive.function.client.awaitBody
import reactor.core.publisher.Mono

@Bean
fun ordersWebClient(builder: WebClient.Builder, props: OrdersProperties): WebClient {
    val connector = ReactorClientHttpConnector(
        reactor.netty.http.client.HttpClient.create()
            .option(ChannelOption.CONNECT_TIMEOUT_MILLIS, 10_000)
            .responseTimeout(Duration.ofSeconds(20))
    )
    return builder
        .baseUrl(props.baseUrl)
        .clientConnector(connector)
        .filter(ExchangeFilterFunction.ofRequestProcessor { request ->
            Mono.just(ClientRequest.from(request).headers { it.setBearerAuth(props.token) }.build())
        })
        .build()
}

@Service
class ReactiveOrdersClient(private val web: WebClient) {
    suspend fun orders(cursor: String?): Page<OrderDto> =
        web.get()
            .uri { it.path("/orders").queryParamIfPresent("cursor", Optional.ofNullable(cursor)).build() }
            .retrieve()
            .awaitBody<Page<OrderDto>>()
}
```

- `awaitBody()` and `awaitBodyOrNull()` are the coroutine bridge. Use them instead of `block()`,
  which is refused on a Reactor thread and stalls unrelated requests where it is not.
- Timeouts belong to the connector, not the builder — `responseTimeout` plus the connect channel
  option. Without them the connect still gives up after Netty's 30 seconds, but a response the
  server never finishes is waited for forever.
- `ExchangeFilterFunction` is this client's interceptor, and filters wrap in the order they are added.

## Spring WebClient — Test Double

```kotlin
class ReactiveOrdersClientTest {
    @Test
    fun orders_cursorGiven_sendsItAndParsesPage() = runTest {
        lateinit var seen: ClientRequest
        val web = WebClient.builder().baseUrl("https://api.example.com").exchangeFunction { request ->
            seen = request
            Mono.just(
                ClientResponse.create(HttpStatus.OK)
                    .header(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_JSON_VALUE)
                    .body("""{"items":[],"nextCursor":"c2"}""").build()
            )
        }.build()

        val page = ReactiveOrdersClient(web).orders("c1")

        assertEquals("/orders?cursor=c1", seen.url().let { "${it.path}?${it.query}" })
        assertEquals("c2", page.nextCursor)
    }
}
```

- `exchangeFunction` replaces the transport, so filters registered on the production builder are not
  in the chain: to assert filter behaviour, build the client the production way and swap in only the
  exchange function.
- WireMock is the better answer once more than one call is under test — it stubs the whole HTTP
  surface, so connector, filters and codecs all stay in play.

## JDK HttpClient

`java.net.http.HttpClient` on JDK 11+, no dependency; `await()` on its `CompletableFuture` is in
`kotlinx-coroutines-core`.

<!-- compile: net -->
```kotlin
import java.net.URI
import java.net.URLEncoder
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse.BodyHandlers
import java.time.Duration
import kotlinx.coroutines.future.await

val jdk: HttpClient = HttpClient.newBuilder()
    .connectTimeout(Duration.ofSeconds(10))
    .followRedirects(HttpClient.Redirect.NORMAL)
    .build()

suspend fun orders(baseUrl: String, cursor: String?, token: String): Page<OrderDto> {
    val query = cursor?.let { "?cursor=" + URLEncoder.encode(it, Charsets.UTF_8) }.orEmpty()
    val request = HttpRequest.newBuilder(URI.create("$baseUrl/orders$query"))
        .timeout(Duration.ofSeconds(20))
        .header("Authorization", "Bearer $token")
        .GET()
        .build()
    val response = jdk.sendAsync(request, BodyHandlers.ofString()).await()
    if (response.statusCode() !in 200..299) throw HttpStatusException(response.statusCode())
    return appJson.decodeFromString(response.body())
}
```

- `sendAsync(...).await()` is the whole coroutine story: `sendAsync` returns a `CompletableFuture`
  and `kotlinx.coroutines.future.await()` cancels it when the coroutine is cancelled. `send()`
  blocks and belongs nowhere near a suspending call.
- A value spliced into the URI is encoded first: a raw `+` in a cursor reaches the server as a space,
  and a `|` makes `URI.create` throw.
- There is no interceptor model, so the header, the retry and the logging are hand-written per call —
  which is exactly why the decision table sends anything past a handful of calls to Ktor.
- Two timeouts, two scopes: `connectTimeout` on the client, `timeout` per request, and the
  per-request one covers the whole exchange rather than one socket read.
- For a test double, `MockWebServer` works here too — point the base URL at `server.url("/")`.
  `HttpClient` has no seam worth stubbing, and subclassing it is more code than a real socket.

## Serializer — kotlinx.serialization

Gradle plugin `org.jetbrains.kotlin.plugin.serialization` plus `libs.kotlinx.serialization.json` —
the only one of the three that exists in `commonMain`.

<!-- compile: jvm -->
```kotlin
import kotlin.time.Instant

@OptIn(ExperimentalSerializationApi::class)
val appJson = Json {
    ignoreUnknownKeys = true      // a new server field must not be an outage
    explicitNulls = false         // omit nulls on the way out, accept absent on the way in
    coerceInputValues = true      // a null in a non-null field falls back to the default
    namingStrategy = JsonNamingStrategy.SnakeCase
}

@Serializable
data class OrderDto(
    val id: String,
    val total: Long,
    val currency: String,
    val placedAt: Instant,
    val status: Status = Status.Unknown,
)

@Serializable
enum class Status { @SerialName("open") Open, @SerialName("closed") Closed, Unknown }
```

Wiring: Retrofit takes `appJson.asConverterFactory("application/json".toMediaType())`; Ktor takes
`install(ContentNegotiation) { json(appJson) }`; Spring takes a
`KotlinSerializationJsonHttpMessageConverter(appJson)`.

- A default value plus `coerceInputValues` is how an unknown enum member stops being a crash; without
  both, one new status on the server takes the screen down.
- `namingStrategy` is the global rule and `@SerialName` the per-field exception — annotating every
  field instead is thirty chances to typo. It is `@ExperimentalSerializationApi`, so it needs an
  opt-in and can change; `@SerialName` alone is the conservative version of the same thing.
- `kotlin.time.Instant` has a built-in serializer, ISO-8601 on the wire; `kotlinx.datetime.Instant`
  is deprecated in its favour.
- Serializers are generated at compile time, so a property whose type has no serializer inside a
  `@Serializable` class is a build error. A class that lacks `@Serializable` itself is not: handed to
  a converter, `body<T>()` or `decodeFromString<T>()`, it compiles and fails on the first call with
  `SerializationException: Serializer for class '…' is not found`.

## Serializer — Moshi

`libs.moshi` plus the KSP processor `libs.moshi.codegen`; `libs.moshi.kotlin` only if reflection is
needed. JVM and Android only.

```kotlin
@JsonClass(generateAdapter = true)
data class OrderDto(
    val id: String,
    val total: Long,
    val currency: String,
    @Json(name = "placed_at") val placedAt: String,
    val status: String = "unknown",
)

val moshi: Moshi = Moshi.Builder()
    .add(InstantAdapter())
    .build()

// Retrofit
.addConverterFactory(MoshiConverterFactory.create(moshi))
```

- Unknown keys are ignored by default — the right default, and the opposite of
  `kotlinx.serialization`'s.
- Codegen (`@JsonClass(generateAdapter = true)`) over `KotlinJsonAdapterFactory`: the reflective
  factory pulls `kotlin-reflect` into the app and reports a missing adapter at runtime.
- Moshi honours Kotlin nullability and defaults: an absent field falls back to its default, and a
  `null` in a non-null field fails with a message naming the field.

## Serializer — Jackson

Spring Boot 4 runs on Jackson 3: packages under `tools.jackson.*`, except the annotations, which stay
in `com.fasterxml.jackson.annotation`. `tools.jackson.module:jackson-module-kotlin` is mandatory on
every Kotlin project; Boot finds it on the classpath and registers it.

<!-- compile: spring -->
```kotlin
import com.fasterxml.jackson.annotation.JsonInclude
import org.springframework.boot.jackson.autoconfigure.JsonMapperBuilderCustomizer
import tools.jackson.databind.PropertyNamingStrategies
import tools.jackson.databind.json.JsonMapper
import tools.jackson.module.kotlin.jacksonMapperBuilder

@Configuration
class JacksonConfig {
    @Bean
    fun jacksonCustomizer() = JsonMapperBuilderCustomizer { builder ->
        builder.propertyNamingStrategy(PropertyNamingStrategies.SNAKE_CASE)
        builder.changeDefaultPropertyInclusion { it.withValueInclusion(JsonInclude.Include.NON_NULL) }
    }
}

// Outside Spring:
val mapper: JsonMapper = jacksonMapperBuilder()
    .propertyNamingStrategy(PropertyNamingStrategies.SNAKE_CASE)
    .build()
```

- Customize Boot's mapper, never replace the bean: a `JsonMapper` bean of your own drops every module
  and `spring.jackson.*` setting Boot applied, and the symptom is a date format that changed for no
  traceable reason.
- Without `jackson-module-kotlin`, Jackson reads the constructor by the parameter names that the Boot
  Gradle plugin's `-java-parameters` compiles in, and ignores the Kotlin defaults: an absent or `null`
  value for a non-null parameter fails with "Parameter specified as non-null is null". With it,
  defaults apply and a `null` for a non-null `val` fails naming the property.
- Jackson 3 already does what the Jackson 2 setup did by hand: `java.time` is built in, dates are
  written as ISO-8601, and unknown properties are ignored. A mapper is immutable once built, so every
  setting goes on the builder.

### Migrating from Jackson 2

- `com.fasterxml.jackson.*` becomes `tools.jackson.*`, annotations excepted; the Kotlin module's group
  is `tools.jackson.module`.
- `Jackson2ObjectMapperBuilderCustomizer` becomes `JsonMapperBuilderCustomizer`; the old one survives
  only in the deprecated `spring-boot-jackson2` module.
- `serializationInclusion(...)` becomes `changeDefaultPropertyInclusion { }`, `registerModule` on a
  built mapper becomes `addModule` on the builder, and `JavaTimeModule` goes.
