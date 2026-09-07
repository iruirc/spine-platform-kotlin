---
name: net-architecture
description: "Use when designing the networking layer of a Kotlin client or the HTTP-client side of a server — the ApiClient boundary, endpoint design, interceptor/plugin middleware order, auth with single-flight token refresh, retry only on idempotent requests, pagination, cancellation, caching, and the testing seams. Library choice lives in net-http-clients."
---

# Networking Architecture

The shape of the layer that speaks HTTP: one interface between the repository and the wire, a fixed
order for the cross-cutting concerns wrapped around it, and a rule for each thing that goes wrong
under load — a token that expires mid-flight, a request that is not safe to repeat, a list that
changes while it is being paged, a screen that leaves while its call is still open. Which library
sits underneath and how it is configured is `net-http-clients`; nothing here depends on the answer.

> **Related skills:**
> - `net-http-clients` — the client and serializer choice, timeouts, pools and the redacting logger this layer configures
> - `net-openapi` — a generated client behind the same interface, and the contract tests that keep it honest
> - `arch-clean` — the layers this boundary answers to, and the DTO rule this skill only points at
> - `arch-hexagonal` — the same boundary on a server, where the API interface is an outbound port
> - `error-architecture` — turning a status code, an `IOException` and a parse failure into one domain error type
> - `concurrency-coroutines` — the scope that owns an in-flight call, and the cancellation that reaches it
> - `reactive-flow` — exposing a polled or streamed endpoint as a `Flow`, and the sharing policy over it
> - `persistence-architecture` — the repository cache this skill hands off to, and source-of-truth policy
> - `architecture-choice` — the compass that names this skill on every stack that leaves the process

## When to Use

- A project is about to grow an HTTP layer and nobody has decided what sits between the repository
  and the client
- User asks "where does the auth header go", "why do I see five refresh calls in the log", "should I
  retry this", "cursor or page number", "why does the request keep running after I leave the screen",
  "OkHttp's cache or my own"
- Review finds a Retrofit interface or a Ktor `HttpClient` injected into a ViewModel, a retry loop
  written at one call site, or a `catch (e: Exception)` wrapped around a suspending call
- The symptom is duplicate POSTs, a burst of parallel token refreshes, or a paged list that shows
  the same row twice

Not for choosing between Retrofit, Ktor and `RestClient` or configuring any of them — that is
`net-http-clients`. Not for a spec-generated client (`net-openapi`), not for where the cached rows
are stored (`persistence-architecture`).

## Core Shape

```
ViewModel / use case      domain types only, no HTTP vocabulary
        |
Repository                DTO -> domain, freshness policy, failure mapping
        |
OrdersApi (interface)     suspend functions, one per endpoint, DTOs out
        |
implementation            the only file that names Retrofit, Ktor or RestClient
        |
middleware                logging -> auth -> retry -> timeout
        |
socket
```

```kotlin
// :data — the seam. Domain-shaped arguments, wire-shaped results, no client type in the signature.
interface OrdersApi {
    suspend fun orders(cursor: String?): Page<OrderDto>
    suspend fun order(id: String): OrderDto
    suspend fun place(draft: OrderDraftDto, idempotencyKey: String): OrderDto
}

data class Page<T>(val items: List<T>, val nextCursor: String?)
```

1. **One interface per API surface, implemented over the chosen client in `:data`.** The
   implementation is the only file that imports the library, so replacing it — or dropping a
   generated client behind it (`net-openapi`) — is one file and no call sites.
2. **DTOs stop at the repository.** `arch-clean` owns that rule and the model families behind it;
   this interface returns DTOs precisely because it sits *below* the repository, and it is the last
   place they are legal.
3. **Arguments are domain-shaped** — an id, a cursor, a draft — not a `Map<String, String>` of query
   parameters and not the client's own request builder. A caller that has to know the query-string
   spelling is calling the transport, not the API.
4. **`suspend` and `Flow`, nothing else.** No `Call<T>`, no `CompletableFuture`, no `Mono`: a client
   that offers only those is adapted inside the implementation (`concurrency-coroutines`).
5. **On a server the same interface is an outbound port** (`arch-hexagonal`) — the core declares it,
   an adapter implements it over the HTTP client, and the core cannot tell it from a database.
6. **Failure mapping happens where the DTOs do.** A status code, a socket failure and a malformed
   body become one domain error type at this boundary, not in the ViewModel (`error-architecture`).

## Middleware Order

Cross-cutting behaviour belongs in one stack around the client, in one order, outermost first.

| # | Layer | Sees | Why here |
|---|---|---|---|
| 1 | logging | one entry per logical call: the final request, its final status, the total elapsed time | outermost, so a call that refreshed a token and retried twice is one line and not four |
| 2 | auth | the 401, and the replay that follows a refresh | above retry, so the request replayed with a refreshed token is one retry then guards |
| 3 | retry | one attempt's failure, and the decision to repeat it | below auth, above the per-attempt timeout |
| 4 | timeout | one attempt | innermost, so each attempt gets its own budget instead of sharing one |

1. **OkHttp names the two halves.** `addInterceptor` registers an *application* interceptor: outside
   OkHttp's own retry-and-follow-up layer, called once per call, seeing the request the app built and
   the response finally returned. `addNetworkInterceptor` registers a *network* interceptor: inside
   that layer, called once per attempt and once per redirect, seeing the bytes actually on the wire —
   the `Authorization` header included. The four rows above are four `addInterceptor` calls in that
   order; application interceptors nest in the order they are added. Reach for a network interceptor
   only when the wire itself is the question — it is skipped entirely when the response comes from
   the cache (`## Caching`), so nothing that must run once per call belongs there.
2. **OkHttp already splits row 4 from the rest**: `callTimeout` bounds the whole call, while
   `connectTimeout`, `readTimeout` and `writeTimeout` bound one attempt. Row 2 has a built-in seat
   too — `authenticator`, called on a 401 with the failed response, returning the replay request or
   `null` to give up, with `Response.priorResponse` available to bound the loop. Take that seat only
   when OkHttp's own follow-up layer *is* row 3: an `Authenticator` runs inside
   `RetryAndFollowUpInterceptor`, below every application interceptor, so an app-level retry added
   with `addInterceptor` would wrap it and put row 3 outside row 2. With an app-level retry, auth is
   an application interceptor that refreshes and replays itself.
3. **Ktor installs the same layering as plugins.** `Auth` and `HttpRequestRetry` both wrap the send
   and nest in install order, the first installed being the outer one, so `install(Auth)` goes above
   `install(HttpRequestRetry)` in the `HttpClient { }` block. `Logging` and `HttpTimeout` sit on
   other pipeline phases, so their position in the block does not change the nesting; what matters is
   that `HttpTimeout` bounds one request execution and `HttpRequestRetry` re-executes, which is row 4.
4. **The order is a property of the client instance, not of a call site.** A retry written inside one
   repository method is invisible to the other twenty, and the twenty-first will be written
   differently. `net-http-clients` covers where that single instance is built.
5. **Nothing above this stack sets a header.** A call site passing `Authorization` by hand means the
   auth layer is not doing its job, and the next endpoint will forget.

## Auth Refresh

One expired token must produce one refresh, however many requests are in flight.

```kotlin
class TokenStore(private val scope: CoroutineScope, private val auth: AuthApi) {
    private val mutex = Mutex()
    private var inFlight: Deferred<Token>? = null
    var current: Token = Token.NONE
        private set

    // `seen` is the token whose request got the 401: if it is no longer the current one,
    // somebody else already refreshed and this caller only has to re-read.
    suspend fun refresh(seen: Token): Token {
        val job = mutex.withLock {
            if (current != seen) return current
            inFlight ?: scope.async {
                try {
                    auth.refresh(seen.refreshToken).also { fresh -> mutex.withLock { current = fresh } }
                } finally {
                    mutex.withLock { inFlight = null }
                }
            }.also { inFlight = it }
        }
        return job.await()
    }
}
```

1. **The refresh runs in an application scope, not the caller's.** Started in a `viewModelScope`, the
   shared `Deferred` dies with the first screen to navigate away and every waiter fails with it
   (`concurrency-coroutines`).
2. **Compare against the token the caller actually sent.** Without that check the second, third and
   fourth 401 each start a refresh of their own once the first has finished.
3. **The refresh request must not travel through the auth layer.** Its own 401 would recurse into
   another refresh; give it a bare client or an exempt path.
4. **A rotating refresh token makes single-flight mandatory, not an optimization.** The server
   invalidates the old refresh token on use, so N parallel refreshes leave N-1 callers holding a dead
   one and the user is signed out for no reason they can describe.
5. **One refresh, one replay.** A 401 on the replayed request is a real authentication failure:
   surface it and sign out (`error-architecture`), do not loop.
6. **Clear the cached `Deferred` on the failure path too.** A refresh that threw and stayed cached
   replays its exception to every caller that arrives afterwards, and the session is dead until the
   process restarts — hence the `finally`.
7. **On Ktor, do not hand-roll any of this.** `Auth`'s `bearer { refreshTokens { } }` is already
   single-flight — it guards the refresh internally and parks parallel callers on its result. A
   hand-rolled store beside it produces two refreshes for one 401.

## Retry

1. **Idempotent methods only** — GET, HEAD, OPTIONS, PUT, DELETE. Never POST or PATCH unless the
   request carries an `Idempotency-Key` the server documents as honoured; without it, the retry of a
   request that did arrive is a second order, a second charge, a second message.
2. **Statuses: 408, 429, 502, 503, 504.** Never any other 4xx — 400, 401, 403, 404, 409 and 422 will
   be exactly as wrong on the second attempt, and 401 is the auth layer's, not this one's. 500 is a
   judgement call per endpoint, not a default.
3. **`Retry-After` outranks the backoff** on 429 and 503, and it may be seconds or an HTTP-date.
   Ignoring it is how a client that was merely rate-limited becomes the reason for an outage.
4. **Exponential backoff with full jitter** — `delay = random(0, min(cap, base * 2^attempt))`. Without
   the random draw every client that failed in the same second retries in the same second, and the
   server that was recovering is knocked back down.
5. **Cap the attempts and cap the wait.** Three attempts and a ceiling of a few seconds; a user
   staring at a spinner has a shorter budget than any backoff curve.
6. **Transport failures follow the same rule.** A connect failure, or any failure before the request
   body was written, is safe to repeat whatever the method. A read timeout on a POST is not: the
   server may have processed it and lost only the response.
7. **Check cancellation before sleeping.** A scope cancelled during a backoff must not wake up and
   fire another request.

```kotlin
suspend fun <T> retrying(max: Int = 3, base: Long = 200, cap: Long = 4_000, body: suspend () -> T): T {
    var attempt = 0
    while (true) {
        try {
            return body()
        } catch (e: RetryableHttpException) {
            currentCoroutineContext().ensureActive()
            if (++attempt >= max) throw e
            delay(e.retryAfterMillis ?: Random.nextLong(minOf(cap, base shl attempt)))
        }
    }
}
```

`RetryableHttpException` is thrown by the layer that classifies responses, so the decision of *what
is retryable* lives in one place and this loop stays a loop (`error-architecture`).

## Pagination

1. **Cursor over offset wherever the list can change.** `?offset=40` over a feed that gained three
   rows since page one returns three rows the user already saw and skips none of them visibly; a
   cursor names a position in the sequence and survives the insert.
2. **One `Page<T>(items, nextCursor)` type, `nextCursor == null` meaning the end.** A caller that has
   to compare `items.size` against a page size to find the end will get it wrong on the page that is
   exactly full.
3. **The cursor lives in the paginator or the repository, never in the ViewModel.** A ViewModel that
   holds it has to re-derive it after process death and has two sources of truth for "where am I".
4. **Offset paging is correct for a stable archive** — an ordered, append-only, rarely-edited list —
   and it is the only option some APIs offer. Say which one the project is on, once.
5. **On Android, `Paging 3` is the consumer of this interface, not a replacement for it**: a
   `PagingSource` whose `load` calls `OrdersApi.orders(cursor)` and maps before returning, with
   `RemoteMediator` for the case where a local database is the source of truth
   (`persistence-architecture`).
6. **On a server, paging is the query's business** — a keyset predicate and a limit, decided in the
   layer that owns the query (`arch-layered`), not bolted on after the rows are in memory.

```kotlin
class OrdersPagingSource(private val api: OrdersApi) : PagingSource<String, Order>() {
    override suspend fun load(params: LoadParams<String>): LoadResult<String, Order> = try {
        val page = api.orders(cursor = params.key)
        LoadResult.Page(page.items.map { it.toDomain() }, prevKey = null, nextKey = page.nextCursor)
    } catch (e: IOException) {
        LoadResult.Error(e)
    }

    override fun getRefreshKey(state: PagingState<String, Order>): String? = null
}
```

## Cancellation

1. **The call dies with the scope that started it.** That is the whole design: a request launched in
   `viewModelScope` is cancelled when the ViewModel clears, and nothing has to remember to cancel it.
   Work that must outlive the screen belongs to an application scope, never to `GlobalScope`
   (`concurrency-coroutines`).
2. **The cancellation has to reach the socket, and it does.** Retrofit's `suspend` support cancels
   the underlying OkHttp `Call` when the coroutine is cancelled; the Ktor client runs the request in
   the caller's job and cancels natively. A hand-written callback bridge does not — an adapter over a
   callback API must call `Call.cancel()` from `suspendCancellableCoroutine`'s `invokeOnCancellation`.
3. **`withTimeout` and the client's timeouts answer different questions.** `withTimeout` bounds the
   whole suspending call — every retry, every refresh, the deserialization — and throws a
   `CancellationException`. The client's connect/read/write timeouts bound one attempt and throw an
   `IOException` the retry layer can act on. Use the client for the transport budget and `withTimeout`
   only for a deadline a human is waiting on.
4. **Cancellation is not a failure.** A `CancellationException` mapped to `UiState.Error` shows an
   error to a user who just pressed Back; caught by a bare `runCatching` it silently keeps a
   cancelled coroutine running. Rethrow it (`error-architecture`, `concurrency-coroutines`).

## Caching

Two caches, two questions, and they are not interchangeable.

| Cache | Keyed by | Answers | Owned by |
|---|---|---|---|
| HTTP cache — OkHttp `Cache`, Ktor `HttpCache` | URL plus varying headers | is this response still fresh according to the server | `Cache-Control`, `ETag`, `Last-Modified` on the response |
| repository cache — in-memory or a database | domain identity | what does the user see with no network, and when is it stale | the repository's own policy |

1. **Let the HTTP cache do what the server told it to.** It handles freshness, revalidation and 304s
   for free; re-implementing `ETag` handling in a repository is a slower copy with fewer cases.
2. **The HTTP cache is not the offline story.** It caches GETs, opaquely, until the server's freshness
   window closes; an app that must work on a train needs domain rows in a database
   (`persistence-architecture`).
3. **The repository cache decides staleness in domain terms** — this list is good for five minutes,
   this profile until the user edits it — and that decision has nowhere else to live.
4. **Scope both to the signed-in user and clear both on sign-out.** A shared HTTP cache holding
   another account's authorized responses is a defect that will be reported as someone else's data.
5. **Never cache a response the server marked `no-store`**, and never add a `Cache-Control` header on
   the client to make a response cacheable that the server refused to.

## Testing

1. **Repository tests fake `OrdersApi`.** The interface exists so that the layer above it can be
   tested with no HTTP at all — no engine, no port, no serializer.
2. **`MockWebServer` for the OkHttp and Retrofit stack.** A real socket on localhost: it exercises the
   interceptor chain, the converter and the URL building, and `takeRequest()` asserts the path,
   method, headers and body that actually went out.
3. **Ktor's `MockEngine` for a Ktor client**, and for anything shared: it needs no socket, so it runs
   in `commonTest` on every target (`pkg-kmp-source-sets`).
4. **The middleware deserves its own tests**, because every one of its rules is invisible at a call
   site: N parallel 401s cause one refresh; a POST is not retried; `Retry-After` is obeyed; a
   cancelled scope cancels the call.
5. **Contract tests belong to the spec** — that the client and the server still agree on the payload
   is `net-openapi`'s question, and a hand-written fixture drifts the day the API changes.
6. **Never let a unit test reach the real network.** It is slow, it fails in CI for reasons no log
   explains, and a red build nobody trusts is worse than no build.

## Common Mistakes

1. **A Retrofit interface or a Ktor `HttpClient` injected into a ViewModel.** The screen now knows
   about status codes and DTOs, the failure mapping is written per screen, and the ViewModel cannot
   be tested without an engine. Everything above the repository sees domain types (`arch-clean`).
2. **Every 401 refreshing its own token.** Four parallel requests expire together, four refreshes
   race, the server rotates the refresh token on first use, and three of them are signed out. One
   `Mutex`, one cached `Deferred`, one refresh.
3. **Retrying a POST.** Without a server-honoured `Idempotency-Key` the retry of a request that did
   arrive is a duplicate order, and the read timeout that triggered it means exactly nothing about
   whether the server processed the first one.
4. **A retry loop written at the call site.** It covers one endpoint, has no jitter, ignores
   `Retry-After` and does not check cancellation — and the next call site will write a different one.
   Retry is a middleware property of the client instance.
5. **Retrying 4xx, or ignoring `Retry-After`.** A 422 is not a transient failure, and a client that
   hammers through a 429 turns rate-limiting into a ban.
6. **`catch (e: Exception)` or a bare `runCatching` around a call.** It swallows
   `CancellationException`, so a cancelled screen's coroutine keeps going and its failure surfaces as
   an error toast on a screen the user already left.
7. **Offset paging over a live feed.** Rows shift between pages, the list shows duplicates, and the
   bug reproduces only while somebody else is posting.
8. **Treating the OkHttp cache as offline support.** It answers freshness questions about URLs, not
   "what do I show with the radio off"; that is a repository cache over stored rows.
9. **A base URL chosen by `if (BuildConfig.DEBUG)` inside the client.** The build type is not the
   environment — staging on a release build, a QA host, a local server all become impossible — and
   the constant is now unreachable from a test. Inject it.
