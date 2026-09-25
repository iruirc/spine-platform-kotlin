# error-architecture — detailed guide

## Contents

- Shared Setup
- The catching Helper
- Client — The Data Error Family
- Client — Platform Exception to DataError
- Client — DataError to Domain
- Client — Domain to UiState
- Client — The Mapper Golden Table
- Server — The Domain Error Family
- Server — Problem Details
- Server — Spring @ControllerAdvice
- Server — Ktor StatusPages
- Server — Micronaut and Quarkus
- Server — Testing the Error Path
- Logging — SLF4J and MDC
- Logging — Timber and Redaction

## Shared Setup

Two chains over one domain: the client chain from an `IOException` to a message on a screen, the
server chain from a domain error to an `application/problem+json` body on four frameworks. The four
server handler sections all read `toProblem()` from `Server — Problem Details`; Ktor and Quarkus
share the `ProblemDetails` type declared in `Server — Ktor StatusPages`, and the client chain's
`isRetryable` is `SKILL.md`'s. The shared type is `data class Order(val id: String, val total: Long)`, packages are
`com.acme`, and the shared discipline is that no mapper below ever sees a `CancellationException`.

## The catching Helper

Every `catching { }` below is `SKILL.md`'s `## The runCatching Rule` helper — one copy per project,
in the module the layers share, and not restated here. Everything below assumes cancellation never
reaches a mapper, which is true only while that helper is the one in use.

The chain needs one more helper, because `kotlin.Result` has `mapCatching` for the success side and
nothing for the failure side:

<!-- compile: net -->
```kotlin
inline fun <T> Result<T>.mapFailure(transform: (Throwable) -> Throwable): Result<T> =
    fold(onSuccess = { Result.success(it) }, onFailure = { Result.failure(transform(it)) })
```

## Client — The Data Error Family

`:data` and nowhere else. A `sealed class` extending `Exception`, not an interface, because it
travels in `kotlin.Result`, whose failure slot is a `Throwable` (`persistence-architecture`) — and
sealed all the same, so the mapper's `when` stays exhaustive.

<!-- compile: net -->
```kotlin
// :data — com/acme/data/orders/DataError.kt
internal sealed class DataError(message: String? = null, cause: Throwable? = null) :
    Exception(message, cause) {

    data class Unreachable(val transport: IOException) : DataError(cause = transport)
    data class Http(val status: Int, val problemType: String?) : DataError("HTTP $status")
    data class Malformed(val error: Throwable) : DataError(cause = error)
    data object Empty : DataError("no rows")
}
```

Four cases cover every client failure worth distinguishing: nothing left the device, something came
back with a status, something came back unparseable, the query matched nothing. `problemType` is the
server's RFC 9457 `type` — the one field of an error body the server promises not to reword.

## Client — Platform Exception to DataError

The one function that speaks Retrofit's vocabulary; swapping the client changes it and nothing above
it (`net-http-clients`). Ktor throws `ClientRequestException` under `expectSuccess`, and Retrofit's
`Response<T>` variant never throws at all — there `isSuccessful` is the branch.

<!-- compile: net -->
```kotlin
// :data — com/acme/data/orders/DataErrorMapping.kt
internal fun Throwable.toDataError(): DataError = when (this) {
    is DataError -> this                                   // already mapped one layer down
    is HttpException -> DataError.Http(code(), response()?.errorBody()?.problemType())
    is SerializationException -> DataError.Malformed(this)
    is IOException -> DataError.Unreachable(this)          // no socket, no DNS, no route, no TLS
    else -> DataError.Malformed(this)
}

internal class OrdersRemoteSource(private val api: OrdersApi) {
    suspend fun order(id: String): Result<OrderDto> =
        catching { api.order(id) }.mapFailure(Throwable::toDataError)
}
```

`HttpException` is tested before `IOException` because a client can make one a subtype of the other
and the first matching arm wins. `else` is `Malformed` rather than a fifth case: an exception this
mapper does not recognise is a bug in the data layer, and is treated as one above.

No `withContext` around the call: Retrofit is on the "nothing to switch" row of
`concurrency-coroutines` → "Per-Layer Dispatchers".

## Client — DataError to Domain

The domain family is `arch-clean`'s: a `sealed class` extending `Exception`, because it rides in
`kotlin.Result`.

<!-- compile: net -->
```kotlin
// :domain — com/acme/domain/orders/OrderError.kt
import kotlin.time.Duration

sealed class OrderError(message: String? = null, cause: Throwable? = null) :
    Exception(message, cause) {

    data object Offline : OrderError()
    data object NotFound : OrderError()
    data object Forbidden : OrderError()
    data class Unavailable(val retryAfter: Duration?) : OrderError()
    data class Rejected(val reason: String) : OrderError(reason)
    data class Unexpected(val error: Throwable) : OrderError(cause = error)
}
```

A `data object` case fills in its stack trace once, at class initialisation, so `Offline`'s own
trace points at the class loader and not at any failure — which is why `Unexpected` carries a
`cause` and why a singleton error's trace is never the one worth logging.

The boundary itself lives in `:data`, where the repository implementation is: `:domain` declares the
port and never imports `DataError`.

<!-- compile: net -->
```kotlin
// :data — the last line at which DataError exists
internal fun DataError.toOrderError(): OrderError = when (this) {
    is DataError.Unreachable -> OrderError.Offline
    is DataError.Http -> when (status) {
        401, 403 -> OrderError.Forbidden
        404, 410 -> OrderError.NotFound
        409, 422 -> OrderError.Rejected(problemType ?: "rejected")
        429, 503 -> OrderError.Unavailable(retryAfter = null)
        else -> OrderError.Unexpected(this)
    }
    is DataError.Malformed -> OrderError.Unexpected(this)
    DataError.Empty -> OrderError.NotFound
}

internal class DefaultOrderRepository(private val remote: OrdersRemoteSource) : OrderRepository {
    override suspend fun order(id: String): Result<Order> =
        remote.order(id).map(OrderDto::toDomain).mapFailure { it.toDataError().toOrderError() }
}
```

`toDataError()` runs again in the repository rather than a cast: its first arm is
`is DataError -> this`, so the second call is free and the chain never needs an `as`. Only the outer
`when` has to be exhaustive, and it is: the compiler breaks this file the day a fifth
`DataError` case appears, which is the whole reason the family is sealed. The inner `when` is over an
`Int` and needs its `else` — and that `else` is a decision: an unmapped status is `Unexpected`, not
"try again", because nobody has yet decided what it means.

## Client — Domain to UiState

The ViewModel is where a locale exists, so it is where an error type becomes something a person
reads. `UiMessage` keeps `Context` and `R` out of the state, so a unit test can compare states with
no device; `arch-mvvm` ships the closed per-message form of this type, and `Literal` is the one
addition, for the string only the server can produce.

```kotlin
// :presentation — com/acme/ui/UiMessage.kt
sealed interface UiMessage {
    data class Resource(@StringRes val id: Int, val args: List<Any> = emptyList()) : UiMessage
    data class Literal(val value: String) : UiMessage   // only for text the server alone can produce
}

@Composable
fun UiMessage.resolve(): String = when (this) {
    is UiMessage.Resource -> stringResource(id, *args.toTypedArray())
    is UiMessage.Literal -> value
}

// the second mapper: one error type, one message, one affordance
internal fun OrderError.toUiMessage(): UiMessage = when (this) {
    OrderError.Offline -> UiMessage.Resource(R.string.error_offline)
    OrderError.NotFound -> UiMessage.Resource(R.string.error_order_gone)
    OrderError.Forbidden -> UiMessage.Resource(R.string.error_not_yours)
    is OrderError.Unavailable -> UiMessage.Resource(R.string.error_busy)
    is OrderError.Rejected -> UiMessage.Resource(R.string.error_rejected)
    is OrderError.Unexpected -> UiMessage.Resource(R.string.error_unexpected)
}
```

`isRetryable`, read by the ViewModel below, is the exhaustive `when` in `SKILL.md`'s `## Retry and
Idempotency`. `Rejected` carries the server's `reason` and this mapper drops it — an identifier for a
log line is not a sentence for a screen, and a rejection needing its own copy needs its own case in
`OrderError`.

```kotlin
class OrderViewModel(private val getOrder: GetOrder, private val reporter: CrashReporter) : ViewModel() {
    private val _state = MutableStateFlow<OrderUiState>(OrderUiState.Loading)
    val state = _state.asStateFlow()

    fun onOpen(id: String) {
        viewModelScope.launch {
            _state.value = getOrder(id).fold(
                onSuccess = { OrderUiState.Content(it.toRow()) },
                onFailure = { throwable ->
                    val error = throwable as? OrderError ?: OrderError.Unexpected(throwable)
                    if (error is OrderError.Unexpected) reporter.record(throwable)
                    OrderUiState.Error(error.toUiMessage(), retryable = error.isRetryable)
                },
            )
        }
    }
}
```

The `reporter` call is the one log in the client chain, and it fires only for the case that
means "the table is wrong".

## Client — The Mapper Golden Table

The mappers are pure functions over closed families, so the test is a list. Adding a case to
`DataError` breaks the mapper's `when`; adding a row here is what makes the new case *deliberate*.

<!-- compile: net-test -->
```kotlin
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.Arguments.arguments
import org.junit.jupiter.params.provider.MethodSource

internal class DataErrorMappingTest {
    @ParameterizedTest(name = "{0} becomes {1}")
    @MethodSource("cases")
    fun toOrderError_everyDataError_mapsToDomainError(input: DataError, expected: OrderError) {
        assertEquals(expected, input.toOrderError())
    }

    companion object {
        @JvmStatic
        fun cases() = listOf(
            arguments(DataError.Unreachable(IOException()), OrderError.Offline),
            arguments(DataError.Http(401, null), OrderError.Forbidden),
            arguments(DataError.Http(404, null), OrderError.NotFound),
            arguments(DataError.Http(422, "quota"), OrderError.Rejected("quota")),
            arguments(DataError.Http(503, null), OrderError.Unavailable(null)),
            arguments(DataError.Empty, OrderError.NotFound),
        )
    }
}
```

Equality works because the domain cases are `data object`s and `data class`es. `Unexpected` wraps a
`Throwable`, whose equality is identity, so it gets its own assertion — which is also where the
"keep the original as a cause" rule is checked:

<!-- compile: net-test -->
```kotlin
import kotlin.test.assertIs

@Test
fun toOrderError_unmappedStatus_becomesUnexpectedWithOriginal() {
    val mapped = DataError.Http(418, null).toOrderError()

    assertIs<OrderError.Unexpected>(mapped)
    assertEquals(418, (mapped.error as DataError.Http).status)
}
```

The two tests nobody writes by hand: the bug they catch shows up as a screen flashing an error the
moment the user leaves it. The second is the library that catches our `CancellationException` and
throws its own — the case only the general arm's `ensureActive()` turns back into a cancellation.

<!-- compile: jvm-test -->
```kotlin
@Test
fun catching_cancelled_rethrowsInsteadOfFailure() = runTest {
    var result: Result<Int>? = null

    val job = launch { result = catching { awaitCancellation() } }
    runCurrent()
    job.cancelAndJoin()

    assertNull(result)   // runCatching would have left Result.failure(CancellationException) here
}

@Test
fun catching_librarySwallowsCancellation_rethrowsInsteadOfFailure() = runTest {
    var result: Result<Int>? = null

    val job = launch {
        result = catching {
            try { awaitCancellation() } catch (e: CancellationException) { throw IllegalStateException("closed") }
        }
    }
    runCurrent()
    job.cancelAndJoin()

    assertNull(result)
}
```

On the state side, assert the *emissions* — `vm.state.test { }` with Turbine — not `state.value` at
the end, which cannot see an `Error` that appeared and was replaced (`reactive-flow`).

## Server — The Domain Error Family

The core's own vocabulary: no status codes, no framework import, nothing an adapter would recognise
(`arch-hexagonal`). Each case carries what a caller might branch on and nothing else.

<!-- compile: ktor -->
```kotlin
// :core — com/acme/orders/OrderError.kt
import kotlin.time.Instant

sealed class OrderError(message: String? = null) : Exception(message) {
    data class NotFound(val id: OrderId) : OrderError("order ${id.value} not found")
    data object Forbidden : OrderError()
    data class InsufficientFunds(val shortfallCents: Long) : OrderError()
    data class Invalid(val violations: List<Violation>) : OrderError()
    data class AlreadyShipped(val shippedAt: Instant) : OrderError()
    data class Conflict(val field: String) : OrderError("duplicate $field")
}

data class Violation(val field: String, val code: String)
```

`Violation` is a domain value, not a framework type: the service knows which field broke which rule,
the adapter only decides it renders as an `errors` member, and a core importing `ConstraintViolation`
has the web framework on the one classpath that must not have it. `Conflict` is where a unique
constraint lands: the persistence adapter catches `DataIntegrityViolationException` (or the driver's
SQLState) and returns this instead, so a duplicate is the 409 the client can act on rather than the
500 an uncaught one becomes (`persistence-jvm-orm`).

## Server — Problem Details

One table, in the web adapter, read by every handler below. RFC 9457 (obsoleting RFC 7807) fixes the
members `type`, `title`, `status`, `detail` and `instance`, and lets you add your own beside them.

<!-- compile: ktor -->
```kotlin
// :adapters:web — com/acme/web/Problems.kt
const val BASE = "https://api.acme.com/problems"

data class Problem(val status: Int, val type: String, val title: String)

fun OrderError.toProblem(): Problem = when (this) {
    is OrderError.NotFound -> Problem(404, "$BASE/order-not-found", "Order not found")
    OrderError.Forbidden -> Problem(403, "$BASE/forbidden", "Not your order")
    is OrderError.InsufficientFunds -> Problem(422, "$BASE/insufficient-funds", "Insufficient funds")
    is OrderError.Invalid -> Problem(422, "$BASE/validation-failed", "Validation failed")
    is OrderError.AlreadyShipped -> Problem(409, "$BASE/already-shipped", "Order already shipped")
    is OrderError.Conflict -> Problem(409, "$BASE/duplicate", "Already exists")
}
```

Two rows share 422 and two share 409, differing only by `type` — which is the reason `type`, and
not `status`, is what a client matches on. What goes on the wire:

```json
{
  "type": "https://api.acme.com/problems/validation-failed",
  "title": "Validation failed",
  "status": 422,
  "detail": "2 fields rejected",
  "instance": "/orders/8f2c1a",
  "requestId": "01J8ZK4Q3M2P",
  "errors": [{ "field": "quantity", "code": "must-be-positive" }]
}
```

`type` is the contract; `title` and `detail` are prose for whoever reads the response by hand, and
both will be reworded. `requestId` is the identifier the log line carries too (`Logging — SLF4J and
MDC`) — the whole support protocol is that the user quotes it and the operator finds the request.

## Server — Spring @ControllerAdvice

```kotlin
@RestControllerAdvice
class OrderErrorHandler {
    private val log = LoggerFactory.getLogger(javaClass)

    @ExceptionHandler(OrderError::class)
    fun handle(e: OrderError): ProblemDetail {
        val (status, type, title) = e.toProblem()
        return ProblemDetail.forStatus(status).apply {
            this.type = URI.create(type)
            this.title = title
            detail = e.message
            setProperty("requestId", MDC.get("requestId"))
            if (e is OrderError.Invalid) setProperty("errors", e.violations)
        }
    }

    @ExceptionHandler(Exception::class)
    fun handleUnmapped(e: Exception): ProblemDetail {
        log.error("unmapped failure", e)                    // the only place a stack trace is written
        return ProblemDetail.forStatus(500).apply {
            this.title = "Internal error"
            setProperty("requestId", MDC.get("requestId"))  // the only detail the caller gets
        }
    }
}
```

`ProblemDetail` is built into Spring 6 and already serializes as `application/problem+json`; a
hand-rolled body beside it is a second vocabulary for the same thing. Two more things finish the job:

1. **`server.error.include-stacktrace` and `server.error.include-message` stay at `never`**, their
   default in Boot 4, for the failures that bypass the advice and reach the `/error` fallback. A
   profile that sets either to `always` for a debugging session and ships is the leak this section
   exists to prevent.
2. **Extend `ResponseEntityExceptionHandler`** rather than writing a bare advice class, so the
   framework's own failures — `MethodArgumentNotValidException`, `HttpMessageNotReadableException` —
   come back in *your* shape instead of making the client parse two vocabularies. Its cheaper half
   is `spring.mvc.problemdetails.enabled=true`, which gives Spring's own exceptions problem bodies
   with no advice class at all; an adapter raising one directly throws
   `ErrorResponseException(HttpStatus.CONFLICT, problemDetail, null)` — a web type, never the core's.

## Server — Ktor StatusPages

<!-- compile: ktor -->
```kotlin
import io.ktor.server.plugins.callid.callId
import kotlinx.serialization.json.Json

@Serializable
data class ProblemDetails(
    val type: String, val title: String, val status: Int,
    val detail: String? = null, val instance: String? = null,
    val requestId: String? = null, val errors: List<FieldError>? = null,
)

@Serializable
data class FieldError(val field: String, val code: String)

suspend fun ApplicationCall.problem(body: ProblemDetails, status: HttpStatusCode) =
    respondText(Json.encodeToString(body), ContentType.Application.ProblemJson, status)

fun Application.installErrorHandling() {
    install(StatusPages) {
        exception<OrderError> { call, e ->
            val (status, type, title) = e.toProblem()
            val body = ProblemDetails(
                type, title, status, e.message, call.request.path(), call.callId,
                errors = (e as? OrderError.Invalid)?.violations?.map { FieldError(it.field, it.code) },
            )
            call.problem(body, HttpStatusCode.fromValue(status))
        }
        exception<Throwable> { call, e ->
            if (e is CancellationException) throw e         // the client hung up; not a 500
            call.application.log.error("unmapped failure", e)
            val body = ProblemDetails("$BASE/internal", "Internal error", 500, requestId = call.callId)
            call.problem(body, HttpStatusCode.InternalServerError)
        }
        status(HttpStatusCode.NotFound) { call, _ ->        // a request that matched no route
            call.problem(ProblemDetails("$BASE/no-such-route", "Not found", 404), HttpStatusCode.NotFound)
        }
    }
}
```

`FieldError` is the wire twin of `Violation`: the domain value stays free of the serialization
plugin, and the adapter that owns the format owns the annotation. `call.callId` is the `CallId`
plugin's (`ktor-server-call-id`), the same id the log line carries. `respondText` with an explicit
`ContentType` is what gets the media type RFC 9457 asks for, and `call.respond(body)` negotiates
`application/json` — the right body under the wrong label, which is why every arm goes through the
one helper. `exception<T>` covers only what a handler threw, so the `status` block is what stops an
unmatched route answering with an empty body and no `type`; and the cancellation arm is not optional
either, because without the rethrow every closed tab is an `error` line and a 500 nobody receives.

## Server — Micronaut and Quarkus

```kotlin
// Micronaut — one bean per domain family; @Error(global = true) on a controller method is the
// other form, for a mapping that needs the request
@Serdeable
data class ProblemBody(
    val type: String, val title: String, val status: Int, val detail: String?, val instance: String?,
)

@Produces
@Singleton
class OrderErrorHandler : ExceptionHandler<OrderError, HttpResponse<*>> {
    override fun handle(request: HttpRequest<*>, e: OrderError): HttpResponse<*> {
        val (status, type, title) = e.toProblem()
        return HttpResponse.status<Any>(HttpStatus.valueOf(status))
            .contentType("application/problem+json")
            .body(ProblemBody(type, title, status, e.message, request.path))
    }
}

// Quarkus — a JAX-RS provider, discovered by the annotation
@Provider
class OrderErrorMapper : ExceptionMapper<OrderError> {
    override fun toResponse(e: OrderError): Response {
        val (status, type, title) = e.toProblem()
        return Response.status(status)
            .type("application/problem+json")
            .entity(ProblemDetails(type, title, status, e.message))
            .build()
    }
}
```

Micronaut Serialization, the JSON layer a generated Micronaut project uses, encodes only a type
annotated `@Serdeable` (or imported with `@SerdeImport`), so the Micronaut body is its own
`@Serdeable` class rather than the Ktor one. Both pick the most specific handler for the thrown
type, so one per sealed family is enough and a second for a subclass splits the mapping in two.
Both also ship a default body for unmapped throwables — replace it before the first deploy, not
after the first leak.

## Server — Testing the Error Path

Two assertions per case, always: the status, and the `type` the client matches on. A test that
asserts only the status passes while the body says something else entirely.

```kotlin
// Spring — MockMvc, the service stubbed to fail
@Test
fun getOrder_forbidden_answers403ProblemWithoutMessage() {
    every { orders.byId(OrderId("42")) } throws OrderError.Forbidden

    mockMvc.get("/orders/42").andExpect {
        status { isForbidden() }
        content { contentType("application/problem+json") }
        jsonPath("$.type") { value("https://api.acme.com/problems/forbidden") }
        jsonPath("$.trace") { doesNotExist() }
    }
}
```

<!-- compile: ktor-test -->
```kotlin
// Ktor — testApplication, the route throwing what the service would
import kotlinx.serialization.json.Json

@Test
fun getOrder_invalid_answers422WithFieldList() = testApplication {
    val invalid = OrderError.Invalid(listOf(Violation("quantity", "must-be-positive")))
    application { installErrorHandling(); routing { get("/orders/42") { throw invalid } } }

    val response = client.get("/orders/42")

    assertEquals(HttpStatusCode.UnprocessableEntity, response.status)
    val body = Json.decodeFromString<ProblemDetails>(response.bodyAsText())
    assertEquals("quantity", body.errors?.single()?.field)
}
```

The `jsonPath("$.trace") { doesNotExist() }` line stops being obvious the moment someone flips a
property for a debugging session and forgets it. One such assertion per service is enough.

## Logging — SLF4J and MDC

One filter puts the request id in the MDC, every log line in the request carries it, and the problem
body hands the same string to the caller.

```kotlin
class RequestIdFilter : OncePerRequestFilter() {
    override fun doFilterInternal(req: HttpServletRequest, res: HttpServletResponse, c: FilterChain) {
        val id = req.getHeader("X-Request-Id") ?: UUID.randomUUID().toString()
        res.setHeader("X-Request-Id", id)
        MDC.putCloseable("requestId", id).use { c.doFilter(req, res) }
    }
}
```

The MDC is thread-local, so it does not survive a dispatcher hop: a `withContext(Dispatchers.IO)`
inside the request loses it silently. `MDCContext` from `kotlinx-coroutines-slf4j` carries it across,
added to the scope's context once, at the boundary that starts the coroutine.

```kotlin
withLoggingContext("orderId" to id.value) {          // kotlin-logging; MDC.put/remove underneath
    log.warn("order refresh failed", e)              // the throwable is an argument, never a string
}
```

1. **The throwable is the last argument, never interpolated.** `log.warn("failed: $e")` prints one
   line and loses the stack trace; `log.warn("failed", e)` keeps it, and the JSON encoder emits it as
   a structured field.
2. **Expected failures are `warn`, bugs are `error`.** If an offline client logs at `error`, the
   error rate is a weather report and the alert on it gets muted.
3. **A structured encoder in every deployed environment** — `logstash-logback-encoder` or the
   equivalent — because MDC members are only searchable when they are fields, not sentences.

## Logging — Timber and Redaction

```kotlin
// Android — planted once in Application.onCreate(); debug logs never reach a release build
class CrashReportingTree : Timber.Tree() {
    override fun log(priority: Int, tag: String?, message: String, t: Throwable?) {
        if (priority < Log.WARN) return
        Firebase.crashlytics.log(message)
        if (t != null && priority >= Log.ERROR) Firebase.crashlytics.recordException(t)
    }
}
```

Only the `Unexpected` case reaches `recordException`; an offline user must not appear in the crash
dashboard at all, or the one real crash is one row among a million.

```kotlin
private val EMAIL = Regex("""[\w.+-]+@[\w-]+(\.[\w-]+)+""")
private val SECRET_HEADERS = setOf("authorization", "cookie", "set-cookie", "proxy-authorization")

fun redact(text: String): String =
    EMAIL.replace(text) { it.value.take(1) + "***@" + it.value.substringAfter('@') }

fun Headers.redacted(): List<String> =
    map { (name, value) -> if (name.lowercase() in SECRET_HEADERS) "$name: <redacted>" else "$name: $value" }
```

1. **Never log a DTO.** A generated `data class` prints every property it has, so one
   `log.debug("received $dto")` ships tokens, emails and postal addresses to a log aggregator whose
   retention nobody chose. Log the id and the count.
2. **`e.printStackTrace()` never ships.** No level, no context, no request id, and on Android it does
   not reach the crash reporter — the stack trace exists only in a logcat buffer nobody is reading.
3. **One `redact` function, shared with the HTTP client's logging interceptor** (`net-http-clients`),
   because a redaction policy that exists in two places is a redaction policy that exists in one.
