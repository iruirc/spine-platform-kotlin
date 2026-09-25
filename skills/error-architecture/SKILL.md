---
name: error-architecture
description: "Use when designing how errors flow through a Kotlin project — sealed error hierarchies vs exceptions vs Result/Either, per-layer mapping (data → domain → presentation, or adapter → core → HTTP), the runCatching cancellation trap, RFC 9457 problem details on the server, @ControllerAdvice / StatusPages, UiState.Error on the client, user messages and localization, logging with PII redaction, retry and idempotency."
---

# Error Architecture

Where a failure is born, what type it wears at each seam it crosses, and what the person on the far
end finally gets — a screen with a Retry button, or an `application/problem+json` body. Not the
syntax of `try`/`catch`: the decision, taken once for the project, about which of a sealed family, a
`Result` and a thrown exception carries a failure across each boundary, and who translates.

> **Related skills:**
> - `concurrency-coroutines` — the cancellation discipline every rule here depends on; the `catching` helper it uses is this skill's
> - `arch-clean` — the use case's return type, `Result<T>` or a sealed outcome: the choice deferred there is taken here
> - `arch-mvvm` — the `UiState.Error` slot this skill fills, and the sealed-vs-data-class shape around it
> - `arch-layered` — the controller or CLI command that turns a service failure into a status code or an exit code
> - `arch-hexagonal` — the adapter edge where a core failure becomes a transport fact
> - `net-architecture` — retry, backoff and idempotency, owned there; the classification they branch on is owned here
> - `net-http-clients` — each client's failure shape: Retrofit's `Response<T>` or a thrown `HttpException`, Ktor's `expectSuccess`
> - `net-openapi` — the problem-details schema published in the spec, and the undocumented status that still needs a mapping
> - `persistence-architecture` — the storage exceptions that stop at the repository, and the source-of-truth policy that decides whether a failure is even visible
> - `reactive-flow` — `catch { }` on a flow, and the `UiState.Error` emission a Turbine test asserts

## When to Use

- A project has grown its second layer and nobody has said what crosses the seam between them
- User asks "`Result` or exceptions", "sealed class or sealed interface for errors", "why did a Back
  press become an error banner", "what goes in the 400 body", "should the repository return `null`"
- Review finds a `runCatching` around a suspending call, a `catch (e: Exception) { null }`, an
  `e.message` rendered into a composable, or a stack trace in an HTTP response
- A server is getting its first `@ControllerAdvice`, `StatusPages` block or `ExceptionMapper`
- A god `AppError` has reached forty cases and every `when` over it ends in an `else`
- A screen shows "Something went wrong" for a case the product owner can name precisely

Not for retry policy, backoff or `Retry-After` — that is `net-architecture` → "Retry". Not for the
shape of the state around the error slot — `arch-mvvm`. Not for the cancellation mechanics these
rules stand on — `concurrency-coroutines`.

`references/detailed-guide.md` lies beside this file; its `## Contents` names the sections — read only the ones the table points to.

## When To Load The Reference

| Need | Reference sections |
|---|---|
| The shared `Order` type, package, and cross-references every mapper below assumes | `Shared Setup` |
| The failure-side `map` that `kotlin.Result` does not ship | `The catching Helper` |
| The data-layer family, and the mapper that produces it | `Client — The Data Error Family`, `Client — Platform Exception to DataError` |
| Where the data family dies and the domain family starts | `Client — DataError to Domain` |
| The ViewModel mapper, and the `UiMessage` it produces | `Client — Domain to UiState` |
| A table test over a mapper, with every case named | `Client — The Mapper Golden Table` |
| A server-side sealed error and its status table | `Server — The Domain Error Family`, `Server — Problem Details` |
| The Spring handler, `ProblemDetail` and the framework's own exceptions | `Server — Spring @ControllerAdvice` |
| The Ktor `StatusPages` block | `Server — Ktor StatusPages` |
| `@Error(global = true)` and `ExceptionMapper<T>` | `Server — Micronaut and Quarkus` |
| Asserting a status and a problem body in a test | `Server — Testing the Error Path` |
| Structured logs with a request id, and what never enters one | `Logging — SLF4J and MDC`, `Logging — Timber and Redaction` |

## Representation

One carrier per seam, chosen once. Mixing all four in one module is the state this table exists to
prevent.

| Carrier | Take when | Cost |
|---|---|---|
| a sealed family per layer — `sealed interface`, or `sealed class : Exception()` | always, for expected failures: this is the vocabulary the mappers and the `when`s are written against | one type per layer, and a mapper at every boundary between them |
| `kotlin.Result<T>` | at a boundary the caller must branch on — a repository's return, a use case's `invoke` | the failure slot is `Throwable`, so the sealed family still has to exist inside it |
| Arrow `Either<E, A>` | the team already uses Arrow, or `raise`/`either { }` is already the house idiom | a library on the domain's classpath, plus everyone learning its vocabulary |
| a thrown exception, uncaught | programmer errors only: a broken invariant, an impossible branch, a missing binding, `require`/`check` | nothing — this is the correct handling of a bug |

1. **Expected failures are values; bugs are exceptions.** "The order is not yours" and "the phone is
   offline" are outcomes the caller must handle, so they get a type. "The mapper hit a branch that
   cannot exist" is a bug, and the right response is a crash in test and a 500 with a correlation id
   in production.
2. **The interface-or-`Throwable` question is decided by the carrier, not by taste.** A family that
   travels in `kotlin.Result` must be a `Throwable`: `sealed class OrderError : Exception()`, the
   form `arch-clean` and `persistence-architecture` both show. A family that travels in your own
   sealed outcome or in `Either` should be a plain `sealed interface` — an error that cannot be
   thrown cannot be thrown by accident.
3. **`kotlin.Result` is one bit until you inspect it.** `Result<T>` says success or failure and
   nothing more; `exceptionOrNull()` returns `Throwable?`, so any per-reason branching is a `when`
   over types, which is the sealed family you would have declared anyway. Promote to a sealed
   outcome the first time a caller writes that `when` (`arch-clean` → "Use Cases").
4. **A `suspend fun` returning `Result<T>` is legal.** The compiler restriction that made people
   invent wrapper types was lifted in Kotlin 1.5; a codebase still routing around it is copying a
   workaround, not a design.
5. **`getOrThrow()` at the wrong altitude undoes the whole thing.** Called in a ViewModel or a
   controller it converts a failure you had modelled back into a crash. It belongs where the caller
   genuinely cannot continue and a bug report is the desired outcome.
6. **One family per layer per bounded area** — `OrderError`, not `AppError`, and not
   `GetOrderByIdError`. Five to fifteen cases is the range where a `when` stays readable.

## Layer-by-Layer Mapping

Every boundary below is where the previous type dies. The mapper is a pure function and its table is
the test.

| Boundary | Arrives as | Leaves as | Mapper lives in |
|---|---|---|---|
| HTTP client, DAO, file → repository | `IOException`, an HTTP status or `HttpException`, `SerializationException`, `SQLiteConstraintException` | `DataError` | `:data`, `internal` |
| repository → use case or service | `DataError` | one sealed domain family, `OrderError` | the repository implementation — the domain never imports `DataError` |
| use case → ViewModel | `OrderError` | `UiState.Error(message: UiMessage)` | the ViewModel |
| service → controller, route, CLI command | the domain family | HTTP status + problem details, or an exit code | the adapter (`arch-layered`, `arch-hexagonal`) |

1. **The mapper is a top-level pure function.** `internal fun Throwable.toDataError(): DataError`,
   `internal fun DataError.toOrderError(): OrderError` — a `when`, no I/O, no logging, no framework,
   no suspension. That is what makes the golden table below possible.
2. **Exhaustive `when`, no `else`.** The `else` is what turns next year's new case into
   "unexpected" without a compiler error. Sealed types plus no `else` means adding a case breaks the
   build at every place that has to decide something about it — the entire point.
3. **The lower type stops at the boundary.** An `HttpException` reaching a ViewModel, or an
   `SQLiteConstraintException` reaching a controller, means one of these mappers does not exist.
4. **The original travels as a `cause`, never as a branch.** `Unexpected(val error: Throwable)`
   exists so the log and the crash report have a stack trace; a caller that inspects `error` inside
   it is doing string archaeology on a type you declined to declare.
5. **Drop detail the next layer cannot act on.** A 503 and a read timeout are the same "try again"
   to a user and to a screen; keep the distinction in the log line, not in the UI vocabulary.
6. **A repository that returns `null` for a failure has thrown the reason away.** The caller cannot
   tell "no such order" from "the network is down" and will guess wrong in the UI.

## The runCatching Rule

`runCatching` catches `Throwable`, and `CancellationException` is a `Throwable`. It is the single
most common way a Kotlin codebase turns a Back press into an error banner while leaving a cancelled
coroutine to fail silently on its next suspension.

```kotlin
// wrong: a Back press becomes an error state, and the cancelled coroutine keeps running
val result = runCatching { repository.load(id) }
```

The helper that replaces it, in every suspending caller:

<!-- compile: jvm -->
```kotlin
suspend inline fun <T> catching(block: () -> T): Result<T> =
    try {
        Result.success(block())
    } catch (e: TimeoutCancellationException) {
        currentCoroutineContext().ensureActive()   // an outer deadline cancelled us — rethrow
        Result.failure(e)                          // our own withTimeout expired — a real failure
    } catch (e: CancellationException) {
        throw e
    } catch (e: Throwable) {
        currentCoroutineContext().ensureActive()   // a library swallowed our cancellation — rethrow
        Result.failure(e)
    }
```

1. **One helper, in one shared module, used everywhere `runCatching` was reached for.** Every
   skill's `catching` is this function, not a second one, and `runCatching` is not used in
   coroutine code.
2. **`ensureActive()` runs before every `Result.failure`.** It throws only when this job is already
   cancelled. In the timeout arm, which comes first because `TimeoutCancellationException` is a
   `CancellationException`, it tells an outer deadline, which must propagate, from a `withTimeout`
   inside the block, a failure the caller must see. In the general arm it catches a library that
   swallowed our cancellation and threw its own exception: without it, the cancelled coroutine
   returns a failure and runs on with `isActive` false.
3. **`catch (e: Exception)` around a suspending call is the same trap in other clothes.** Where the
   helper does not fit, the first arm is `catch (e: CancellationException) { throw e }`, and the
   general arm calls `currentCoroutineContext().ensureActive()` before it handles anything.
4. **Cancellation is never mapped, logged as an error, reported, or shown.** It is not a failure of
   anything; it is the machinery telling you the caller left. A `CancellationException` arriving in
   a mapper's `when` means rule 1 was skipped somewhere upstream.
5. **A `finally` that must still run needs `withContext(NonCancellable)`** — releasing a lock,
   writing a final audit row. Business work inside it is an uncancellable coroutine.

## Server Presentation

RFC 9457 (which obsoletes RFC 7807) is the default body for every error response: media type
`application/problem+json`, members `type`, `title`, `status`, `detail`, `instance`, plus your own
extension members alongside them.

| Framework | Hook | Body |
|---|---|---|
| Spring Boot | `@RestControllerAdvice` with `@ExceptionHandler`; extend `ResponseEntityExceptionHandler` to also cover the framework's own | `ProblemDetail`, built into Spring 6 |
| Ktor | `install(StatusPages) { exception<OrderError> { call, e -> call.respondText(json, ContentType.Application.ProblemJson, status) } }` | your own `@Serializable ProblemDetails` |
| Micronaut | `@Error(global = true)` handler, or an `ExceptionHandler<E, HttpResponse<*>>` bean | your own type |
| Quarkus | `@Provider class OrderErrorMapper : ExceptionMapper<OrderError>` | your own type |

1. **The mapping table lives in the adapter, once.** A status code is a transport fact, so it is
   decided where transport lives, not in the service and never in the domain (`arch-hexagonal`,
   `arch-layered`). One handler per domain family beats one `@ExceptionHandler` per endpoint.
2. **`type` is a stable URI and it is the identifier clients match on.**
   `https://api.example.com/problems/insufficient-funds` — not the localized `title`, and not the
   `detail`, both of which are prose you will reword. It defaults to `about:blank`, which says only
   "the status code is the whole story", so a mapped failure that leaves it unset is unidentifiable.
   Publish the types in the OpenAPI spec (`net-openapi`).
3. **Validation failures are 400, or 422 when the syntax was fine and the rule was not**, and they
   carry the per-field list as an extension member — `errors: [{ "field": …, "code": … }]`. A
   validation response with one flattened sentence forces the client to parse English.
4. **Never leak a stack trace, an SQL fragment, a class name, an internal id or an upstream URL.**
   Spring Boot already defaults `server.error.include-stacktrace` and `include-message` to `never`;
   the leak is a profile that flips them, Quarkus' dev-mode exception page facing real users, and the
   `e.message` that every `StatusPages` sample puts in the body. A 5xx body says nothing beyond its
   `type`, its `title` and a correlation id.
5. **`instance` identifies this occurrence — usually the request path — and a `requestId`
   extension member carries the correlation id that is also in the log line.** That is the whole
   support protocol: the user quotes one opaque string, the operator finds the MDC entry with it.
6. **A failure with no mapping is a 500 with a correlation id, and that is correct** — but the
   handler that produces it logs at `error` with the stack trace, because an unmapped case is a bug
   in the table, not a fact about the request.
7. **`detail` is for developers.** Server-side messages are not user copy: the client owns what a
   person reads, in the person's language (see `## Localization`).

## Client Presentation

Three classes, decided by the error type and nothing else. The composable renders the decision; it
does not take it.

| Class | The user can | Affordance |
|---|---|---|
| recoverable | try again and it may work — offline, timeout, 429, 503 | content stays on screen; a `Snackbar` or an inline row with a Retry action |
| non-recoverable | not fix it by retrying, but can leave — 404, 403, a rejected order, a closed window | a screen-level error state with a way out: Back, sign in, correct the input |
| fatal | do nothing; the process cannot continue — a corrupt database, a failed mandatory migration | report to crash reporting, then a relaunch or reset screen |

```kotlin
// :presentation — a message identity, not a String: the composable resolves it.
sealed interface UiMessage {
    data class Resource(@StringRes val id: Int, val args: List<Any> = emptyList()) : UiMessage
    data class Literal(val value: String) : UiMessage   // only for text the server owns, e.g. a quota
}
```

1. **The class is a property of the error type**, so it is decided in the mapper, not at the call
   site: two screens showing the same failure differently is a bug someone reports as inconsistency.
2. **Never replace content the user already has with a full-screen error.** A refresh that failed
   over a loaded list is a `Snackbar` with Retry; the full-screen state is for the first load, when
   there is nothing behind it.
3. **Inline is for the field that caused it.** A per-field validation error next to the field, not
   in a dialog the user must dismiss before they can see which field it meant.
4. **Every error state has an exit.** A screen with a message and no button is a dead end the user
   escapes by force-quitting.
5. **`UiMessage` keeps `Context` and `R` out of the ViewModel** — the state stays comparable in a
   unit test with no device. `arch-mvvm` shows the closed per-message form of the same slot, one
   identity per message; the `Literal` case above is the one addition, for the string only the
   server can produce.
6. **Where the error sits in the state — a `sealed interface` member or a nullable field beside the
   content — is `arch-mvvm`'s table**, and it is the same decision as "does content survive the
   error", which rule 2 already answered for you.

## Localization

1. **A user-facing message is resolved in the UI layer, from an error *type*.** The data layer knows
   `HTTP 409`; the domain knows `OrderError.AlreadyShipped`; only the UI knows the device's locale,
   the screen's tone, and whether this screen calls it an order or a booking.
2. **No `String` message crosses the domain boundary** as the thing to display. A `Rejected(val
   reason: String)` case is a message from the server to a developer; a screen that renders it is
   showing the user text nobody translated and nobody proofread.
3. **`e.message` is never user copy.** It is a developer string, sometimes null, sometimes a class
   name, sometimes the URL that failed.
4. **Server-side `title` and `detail` are developer-facing**, and the `type` URI is the stable
   identifier a client maps to its own localized message. A client that switches on `title` breaks
   the day someone fixes a typo.
5. **The one string the server owns is one it alone can produce** — a remaining quota, a next
   allowed date. It arrives as an extension member with the value, not as a rendered sentence, and
   the client formats it: `UiMessage.Resource(R.string.quota_left, listOf(remaining))`.

## Logging and PII

1. **Log once, at the boundary that handles the failure.** Three layers each logging "failed to load
   order 42" is three lines and one event. The repository maps, the ViewModel or the exception
   handler logs.
2. **Structured, with a request id.** SLF4J with MDC on the server (`withLoggingContext { }` from
   kotlin-logging, or `MDC.putCloseable` in a filter), Timber on Android. The id in the MDC is the
   one the problem body returns as `requestId`.
3. **Expected failures are `warn` or `info`; only a bug is `error`.** An offline phone logged at
   `error` trains everyone to ignore the error level.
4. **`e.printStackTrace()` never ships.** It writes to stderr with no level, no context, no
   correlation id, and on Android it does not reach the crash reporter at all. Pass the throwable as
   the logger's last argument instead: `log.warn("order refresh failed", e)`.
5. **Never log a DTO's `toString()`.** A generated `data class` prints every field it has, which is
   how tokens, emails and full addresses reach a log aggregator nobody audited. Log ids.
6. **Redact at one place, by a named function.** `Authorization` and `Cookie` headers, bearer and
   refresh tokens, emails, phone numbers, payment data, precise coordinates. `net-http-clients`
   covers the client's own logging interceptor; the same `redact` function serves both.
7. **Crash reporting gets bugs, not outcomes.** Send the unmapped and `Unexpected` cases; sending
   every caught failure buries the one crash that matters under a million offline users.

## Retry and Idempotency

`net-architecture` → "Retry" owns the policy — idempotent methods only, the 408/429/502/503/504
list, `Retry-After` outranking the backoff, full jitter, capped attempts, and the cancellation check
before the sleep. This skill owns one thing it depends on: **retryability is a property of the error
type**, declared once, next to the type.

```kotlin
val OrderError.isRetryable: Boolean
    get() = when (this) {
        OrderError.Offline, is OrderError.Unavailable -> true
        OrderError.NotFound, OrderError.Forbidden, is OrderError.Rejected -> false
        is OrderError.Unexpected -> false
    }
```

1. **One declaration, two readers.** The retry loop branches on it, and so does the presentation
   class in `## Client Presentation`: recoverable and retryable are the same predicate seen from two
   sides.
2. **A retry of a non-idempotent write needs a key the domain owns.** The `Idempotency-Key` is
   generated once per user intent, survives the retry, and is checked by the server — a transport
   header carrying a domain value (`arch-layered`).
3. **A retry that exhausts its attempts surfaces the last error, not a new one.** "Failed after 3
   attempts" as its own case loses which failure it was, and the mapper below it has nothing to
   branch on.

## Testing Error Paths

1. **Every mapper gets a golden table.** One `@ParameterizedTest` with a `(input, expected)` list is
   the whole test; adding a case to the sealed family and forgetting the row is the failure it is
   there to produce. The reference shows the shape.
2. **Assert the mapped type, never the message.** `assertIs<OrderError.NotFound>(…)` survives a copy
   change; `assertEquals("Not found", …)` does not.
3. **A cancellation test is worth writing once per helper**: cancel the scope mid-call and assert the
   state never became `Error` — the regression the `runCatching` rule exists to prevent, and the one
   nobody notices by hand.
4. **On the client, assert the emission, not the final value.** Turbine over the state flow catches
   an `Error` that flashed and was replaced; `state.value` at the end does not (`reactive-flow`).
5. **On the server, assert the status *and* the body.** `MockMvc` on Spring, `testApplication` on
   Ktor: status, `Content-Type: application/problem+json`, and the `type` member — the last one is
   the contract clients actually match on.
6. **One test asserts that no stack trace ships.** A response body containing the exception class
   name is a leak that no code review catches twice in a row.

## Common Mistakes

1. **`runCatching` around a suspending call.** It catches `CancellationException`: a Back press
   becomes an error banner, and the coroutine everyone thinks recovered stays cancelled and fails on
   its next suspension. Use the `catching` helper above.
2. **`Result<Result<T>>`.** `runCatching { repo.load(id) }` where `load` already returns a `Result`
   produces a success wrapping a failure, so every `onFailure` on it is dead code — and
   `mapCatching` nests exactly the same way when its transform returns a `Result`. Call the inner
   function directly, or `fold` over the one you have.
3. **A `String` message crossing the domain.** Once a failure carries the sentence to display, the
   locale is decided in the layer that has no locale, the UI cannot reword per screen, and nobody
   can tell which literal the server can be trusted to send.
4. **`catch (e: Exception) { return null }` at the repository.** The caller cannot distinguish "no
   such order" from "the disk is full", so the UI shows an empty state for an outage — and the
   original exception is gone before anything logged it.
5. **`throw` for an expected outcome.** "Insufficient funds" is a business result and belongs in the
   return type. Thrown, it is invisible to the compiler, forgotten by one caller, and caught by a
   `catch (e: Exception)` three layers up that turns it into "Something went wrong".
6. **A stack trace, class name or SQL fragment in an HTTP body.** It is an information leak, and it
   is a contract nobody meant to publish: the day the internal class is renamed, a client breaks.
7. **Logging at every layer.** The data source logs, the repository logs, the use case logs, the
   ViewModel logs — four lines per failure, none of them the one with the context. Log where it is
   handled.
8. **`Exception` subclass hierarchies where a sealed family fits.** An open exception class means a
   `when` over it can never be exhaustive, the compiler stops helping, and every branch grows an
   `else`. Seal it, and let the build break when a case is added.
9. **DTO error codes reaching the UI.** `when (code) { "ERR_4412" -> … }` in a composable makes the
   screen depend on a backend enum: the mapping table now lives in the layer that can least afford to
   change, and the string is untranslatable.
10. **A god `AppError`.** Every layer adds cases, every `when` needs an `else`, and no caller can
    know which subset it can actually receive. One family per layer per bounded area, mapped between.
11. **Catching an error just to rethrow it wrapped in a new one at every layer.** Three wrappers deep,
    the stack trace is intact and the type says nothing; a mapper replaces the type deliberately at
    one boundary, it does not accumulate.
