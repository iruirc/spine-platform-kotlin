# net-http-clients — detailed guide

One API — `GET /orders?cursor=…` returning a page, `POST /orders` creating one — configured on each
client of `SKILL.md`'s decision table, then doubled in a test, plus one setup per serializer. Every
section is self-contained; load the one you need, not the file. The payload they share, behind the
`OrdersApi` boundary `net-architecture` declares:

```kotlin
@Serializable
data class OrderDto(val id: String, val total: Long, val currency: String)

@Serializable
data class PageDto(val items: List<OrderDto>, val nextCursor: String? = null)
```

The middleware order each configuration follows — logging outside auth, auth outside retry, timeout
innermost — and the `TokenStore` the auth pieces call are `net-architecture`'s. Dependencies are
written as version-catalog aliases.

## Retrofit + OkHttp

`libs.retrofit`, `libs.retrofit.kotlinx.serialization`, `libs.okhttp`, `libs.okhttp.logging`.

```kotlin
private val appJson = Json { ignoreUnknownKeys = true; explicitNulls = false }

private val logging = HttpLoggingInterceptor().apply {
    level = if (BuildConfig.DEBUG) Level.BODY else Level.NONE
    redactHeader("Authorization")
    redactHeader("Cookie")
}

// OkHttp calls this on a 401, on its own dispatcher thread, and retries whatever it returns.
private class RefreshAuthenticator(private val tokens: TokenStore) : Authenticator {
    override fun authenticate(route: Route?, response: Response): Request? {
        if (response.priorResponse != null) return null
        val seen = response.request.header("Authorization")?.removePrefix("Bearer ") ?: return null
        val fresh = runBlocking { tokens.refresh(seen) } ?: return null
        return response.request.newBuilder()
            .header("Authorization", "Bearer ${fresh.access}")
            .build()
    }
}

val http: OkHttpClient = OkHttpClient.Builder()
    .connectTimeout(Duration.ofSeconds(10))
    .readTimeout(Duration.ofSeconds(20))
    .callTimeout(Duration.ofSeconds(60))
    .addInterceptor(logging)
    .addInterceptor(AuthInterceptor(tokens))
    .authenticator(RefreshAuthenticator(tokens))
    .cache(Cache(File(cacheDir, "http"), 20L * 1024 * 1024))
    .build()

val retrofit: Retrofit = Retrofit.Builder()
    .baseUrl("https://api.example.com/")
    .client(http)
    .addConverterFactory(appJson.asConverterFactory("application/json".toMediaType()))
    .build()

interface OrdersService {
    @GET("orders")
    suspend fun orders(@Query("cursor") cursor: String?): PageDto

    @POST("orders")
    suspend fun place(@Body draft: OrderDraftDto, @Header("Idempotency-Key") key: String): OrderDto
}

val service: OrdersService = retrofit.create()
```

- `AuthInterceptor` is the three lines this omits: read the current token and copy it into an
  `Authorization` header. Its `runBlocking`, like the one above, is legitimate — `Interceptor` and
  `Authenticator` are blocking callbacks OkHttp invokes on its own dispatcher threads, never on the
  caller's. That is the exception behind the mistake in `SKILL.md`, which is about call sites.
- `authenticator` is the seat for row 2 of the middleware order, and `priorResponse` is what stops an
  endlessly re-challenged request from looping.
- `baseUrl` must end in `/` and a `@GET` path must not begin with one, or resolution drops a segment.
  Retrofit instances are cheap; share one `OkHttpClient` and use `newBuilder()` for variants.

## Retrofit + OkHttp — Test Double

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
    fun stop() = server.shutdown()

    @Test
    fun `sends the cursor and parses the page`() = runTest {
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Type", "application/json")
                .setBody("""{"items":[{"id":"o1","total":1250,"currency":"EUR"}],"nextCursor":"c2"}""")
        )

        val page = service.orders(cursor = "c1")

        val sent = server.takeRequest()
        assertEquals("GET", sent.method)
        assertEquals("/orders?cursor=c1", sent.path)
        assertEquals("c2", page.nextCursor)
        assertEquals("o1", page.items.single().id)
    }
}
```

- `takeRequest()` is the assertion surface — path, method, headers and body exactly as they went out,
  and the only way to prove an interceptor added the header it was supposed to.
- `setBodyDelay` and `throttleBody` are how the timeouts get tested; a stub that answers instantly
  proves nothing about the four durations set on the client.
- OkHttp 5 moved the package to `mockwebserver3` and replaced the setters with `MockResponse.Builder`.
  The client here is bare because the subject is the Retrofit interface; to test the interceptor
  stack, build the real one against `server.url("/")`.

## Ktor Client

`libs.ktor.client.core`, one engine per target (`libs.ktor.client.okhttp`, `.darwin`, `.cio`, `.js`),
plus `content.negotiation`, `serialization.kotlinx.json`, `auth` and `logging`.

```kotlin
val appJson = Json { ignoreUnknownKeys = true; explicitNulls = false }

fun ordersHttpClient(engine: HttpClientEngine, tokens: TokenStore, isDebug: Boolean) =
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
                loadTokens { tokens.current()?.let { BearerTokens(it.access, it.refresh) } }
                refreshTokens { tokens.refreshed(oldTokens?.refreshToken)?.let { BearerTokens(it.access, it.refresh) } }
                sendWithoutRequest { true }
            }
        }
        install(HttpRequestRetry) {
            retryOnServerErrors(maxRetries = 3)
            retryOnExceptionIf { _, cause -> cause is IOException }
            exponentialDelay(base = 2.0, maxDelayMs = 4_000)
        }
        install(HttpTimeout) {
            connectTimeoutMillis = 10_000
            requestTimeoutMillis = 30_000
            socketTimeoutMillis = 20_000
        }
    }

class KtorOrdersApi(private val http: HttpClient) : OrdersApi {
    override suspend fun orders(cursor: String?): PageDto =
        http.get("orders") { cursor?.let { parameter("cursor", it) } }.body()

    override suspend fun place(draft: OrderDraftDto, idempotencyKey: String): OrderDto =
        http.post("orders") {
            header("Idempotency-Key", idempotencyKey)
            setBody(draft)
        }.body()
}
```

- `refreshTokens` is already single-flight — the bearer provider guards it and parks parallel callers
  on one result. Do not add a `Mutex`: that is the hand-rolled store `net-architecture` describes for
  clients with no such plugin.
- `sendWithoutRequest { true }` sends the bearer header up front; without it the client waits for a
  401 challenge on the first request to each host, doubling the round trips.
- `expectSuccess = true` turns a non-2xx into `ClientRequestException` / `ServerResponseException`;
  without it `body()` parses the error page and the failure names the serializer, not the status.
- `HttpTimeout` bounds one request execution and `HttpRequestRetry` re-executes, so each attempt gets
  its own budget; per-call overrides go in the request builder's `timeout { }` block.
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
    fun `sends the cursor and parses the page`() = runTest {
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

For streaming, uploads and anything with no typed API worth declaring. `libs.okhttp`, plus `libs.okio`
where the body is written straight to disk.

```kotlin
suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    cont.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) = cont.resume(response)
        override fun onFailure(call: Call, e: IOException) {
            if (!cont.isCancelled) cont.resumeWithException(e)
        }
    })
}

// A long download shares the pool and the interceptors, and drops only the read timeout.
private val streaming = http.newBuilder().readTimeout(Duration.ZERO).build()

suspend fun download(url: String, into: File) = withContext(Dispatchers.IO) {
    val request = Request.Builder().url(url).build()
    streaming.newCall(request).await().use { response ->
        if (!response.isSuccessful) throw HttpStatusException(response.code)
        response.body!!.byteStream().use { source ->
            into.outputStream().use { sink -> source.copyTo(sink) }
        }
    }
}
```

- `invokeOnCancellation { cancel() }` is what makes the call structured: without it a cancelled
  coroutine leaves the socket open until the response arrives and is discarded.
- `newBuilder()` shares the pool, the dispatcher and the cache with its parent; a second
  `OkHttpClient.Builder()` shares nothing — the per-request-client mistake in slow motion.
- `Response` and its body are `Closeable` even when the body is not read: `use`, every time, or a
  leaked body holds a connection out of the pool forever.
- `readTimeout(Duration.ZERO)` disables the read timeout for the streaming variant only; keep
  `callTimeout` off it too, or a large file is cut mid-transfer.

## OkHttp Alone — Test Double

```kotlin
class DownloadTest {
    private val server = MockWebServer()

    @Test
    fun `a cancelled scope cancels the call`() = runTest {
        server.enqueue(MockResponse().setBody("payload").setBodyDelay(10, TimeUnit.SECONDS))
        server.start()

        val job = launch { download(server.url("/file").toString(), File.createTempFile("dl", null)) }
        job.cancelAndJoin()

        assertTrue(job.isCancelled)
    }
}
```

- The cancellation test is the one that pays for itself: it is how a `suspendCancellableCoroutine`
  bridge that forgot `invokeOnCancellation` is found, and it fails as a hang.
- `server.url("/file")` is a real URL on a random free port, so tests parallelize with no fixture.

## Spring RestClient

`org.springframework:spring-web` (Spring Framework 6.1+, Boot 3.2+). Blocking, and on virtual threads
that is no longer a reason to reach for the reactive stack.

```kotlin
@Configuration
class OrdersClientConfig {
    @Bean
    fun ordersRestClient(builder: RestClient.Builder, props: OrdersProperties): RestClient =
        builder
            .baseUrl(props.baseUrl)
            .requestFactory(SimpleClientHttpRequestFactory().apply {
                setConnectTimeout(Duration.ofSeconds(10))
                setReadTimeout(Duration.ofSeconds(20))
            })
            .requestInterceptor { request, body, execution ->
                request.headers.setBearerAuth(props.token)
                execution.execute(request, body)
            }
            .defaultStatusHandler(HttpStatusCode::is5xxServerError) { _, response ->
                throw RetryableHttpException(response.statusCode.value())
            }
            .build()
}

@Service
class OrdersClient(private val rest: RestClient) {
    fun orders(cursor: String?): PageDto =
        rest.get()
            .uri { it.path("/orders").queryParamIfPresent("cursor", Optional.ofNullable(cursor)).build() }
            .retrieve()
            .body(PageDto::class.java)!!
}
```

- Inject the `RestClient.Builder` bean rather than calling `RestClient.create()`: Boot has already
  applied its customizers, the observation registry and the message converters to it.
- One `RestClient` per remote service, each with its own base URL and timeouts; a shared one with
  absolute URLs at call sites has nowhere left to set a per-service budget.
- `defaultStatusHandler` is where a status becomes an exception the retry layer can classify — the
  default throws `RestClientResponseException` for everything (`error-architecture`). And this
  blocks: call it in `withContext(Dispatchers.IO)`, or run on virtual threads.

## Spring RestClient — Test Double

```kotlin
class OrdersClientTest {
    private val builder = RestClient.builder().baseUrl("https://api.example.com")
    private val server = MockRestServiceServer.bindTo(builder).build()
    private val client = OrdersClient(builder.build())

    @Test
    fun `sends the cursor and parses the page`() {
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
- `server.verify()` turns an unmet `expect` into a failure; without it, a client that made no call at
  all is green.
- The same class doubles `RestTemplate` — the other half of why migrating to `RestClient` is cheap.

## Spring WebClient

`org.springframework:spring-webflux` plus a connector. Take it when the caller is already reactive;
it pulls the reactive stack into a servlet application otherwise.

```kotlin
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
    suspend fun orders(cursor: String?): PageDto =
        web.get()
            .uri { it.path("/orders").queryParamIfPresent("cursor", Optional.ofNullable(cursor)).build() }
            .retrieve()
            .awaitBody()
}
```

- `awaitBody()` and `awaitBodyOrNull()` are the coroutine bridge. Use them instead of `block()`,
  which is refused on a Reactor thread and stalls unrelated requests where it is not.
- Timeouts belong to the connector, not the builder — `responseTimeout` plus the connect channel
  option. A `WebClient` with neither waits forever.
- `ExchangeFilterFunction` is this client's interceptor, and filters wrap in the order they are added.

## Spring WebClient — Test Double

```kotlin
class ReactiveOrdersClientTest {
    @Test
    fun `sends the cursor and parses the page`() = runTest {
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

## Serializer — kotlinx.serialization

Gradle plugin `org.jetbrains.kotlin.plugin.serialization` plus `libs.kotlinx.serialization.json` —
the only one of the three that exists in `commonMain`.

```kotlin
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
    val placedAt: Instant,                              // kotlinx-datetime serializes this already
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
  field instead is thirty chances to typo.
- Serializers are generated at compile time, so a missing `@Serializable` is a build error rather
  than a runtime one. That is why this is the default for new code.

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

`com.fasterxml.jackson.module:jackson-module-kotlin` is mandatory on every Kotlin project; Boot
registers it automatically once it is on the classpath.

```kotlin
@Bean
fun jacksonCustomizer() = Jackson2ObjectMapperBuilderCustomizer { builder ->
    builder.propertyNamingStrategy(PropertyNamingStrategies.SNAKE_CASE)
    builder.serializationInclusion(JsonInclude.Include.NON_NULL)
    builder.featuresToDisable(
        DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES,
        SerializationFeature.WRITE_DATES_AS_TIMESTAMPS,
    )
}

// Outside Spring:
val mapper: ObjectMapper = jacksonObjectMapper().apply {
    registerModule(JavaTimeModule())
    disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
}
```

- Customize Boot's mapper, never replace the bean: a fresh `ObjectMapper` bean drops every module
  Boot registered, and the symptom is a date format that changed for no traceable reason.
- Without `jackson-module-kotlin` there are no constructor parameter names, no default arguments and
  no nullability — Jackson writes `null` into a non-null `val` and the `NullPointerException` lands
  somewhere else entirely.
- `JavaTimeModule` with `WRITE_DATES_AS_TIMESTAMPS` disabled is what makes an `Instant` an ISO-8601
  string instead of an epoch decimal.
