---
name: release-ops-server
description: "Use when resolving release ops for a Kotlin JVM server — container images (Jib vs Dockerfile, distroless base), health/readiness/liveness probes, twelve-factor configuration, graceful shutdown, migrations on deploy (expand/contract), observability (Micrometer, OpenTelemetry, structured logs), rollout strategies (blue-green, canary) and the change-freeze calendar."
---

# Release Ops — Server

The server half of spine-toolkit's **release ops** topic: what a Kotlin JVM service has to answer
when the "distribution channel" is a deploy rather than a store — how the image is built, what the
orchestrator asks it, where configuration and secrets come from, how it stops without dropping a
request, and how a schema change rides a rollout. Versioning, CI lanes, crash reporting, feature
flags and secrets in CI are shared with every target and live in `release-ops`.

> **Related skills:**
> - `release-ops` — the immutable image tag rollback depends on, the CI lanes that build it, and the feature flags a rollout leans on
> - `persistence-migrations` — expand/contract and the per-engine mechanics; this skill only says who runs them and when
> - `arch-layered` — the layering a probe, a shutdown hook and a config binding attach to
> - `arch-hexagonal` — the same, where the framework sits in an adapter and the core knows nothing about the deploy
> - `di-spring` — typed configuration properties, profiles, and the container that owns the beans being shut down
> - `net-architecture` — timeouts, retries and idempotency, which decide what "drain in-flight" is even able to promise

## When to Use

- `spine-toolkit:feature-estimation` needs a release-review buffer for a service or a verdict on
  platform fragmentation, or `spine-toolkit:ops-checklist` has a **Release ops** row to settle
- `spine-toolkit:feature-requirements` put a probe, a freeze window or an observability signal in
  the secondary list
- A service is going into a container for the first time, or the image is 900 MB
- Every deploy produces a burst of 502s, or a rolling update restarts pods it should have drained
- A schema change has to ship without downtime and nobody has said where the migration runs
- User asks "Jib or a Dockerfile", "liveness or readiness", "how do we roll back", "where do the
  secrets come from", "blue-green or canary"
- Review finds migrations on application startup, a liveness probe that queries the database,
  configuration baked into the image, a `latest` tag, or free-text logs

Not for the migration itself (`persistence-migrations`), not for the shared build concerns
(`release-ops`), and not for the internal structure of the service (`arch-layered`,
`arch-hexagonal`).

## Distribution-channel review

**`Release review` — the platform's answer to core's calendar-buffer key, for a server: none —
0 calendar days.** There is no store and no gate; shipping is a decision the team makes and can
unmake. What can still be a calendar buffer is a **change-freeze window the team declares** — a peak
trading season, an audit, a customer's maintenance calendar, a regulated release board — and when
one is in force that window, not a review queue, is the value core's key takes.

1. **State the freeze or state that there is none.** An implicit freeze is discovered by the
   estimate that missed it; a declared one is a date range in the plan.
2. **A freeze is calendar time, never engineering days.** It is wall-clock waiting on the same line
   as any other release buffer, and it is never folded into the day range.
3. **Internal gates count.** A change-advisory board, a mandatory soak, or a security sign-off is the
   same kind of wait as a store review and belongs on the same line.

## Containers

| Take | When |
|---|---|
| **Jib** (`com.google.cloud.tools.jib`) | the default: no Dockerfile, no Docker daemon in CI, reproducible layers split into dependencies / resources / classes, so a code-only change pushes a tiny layer |
| **A Dockerfile**, multi-stage | the image needs OS packages, a native binary, a custom entrypoint, or the organisation's own scanned base image |

```kotlin
// build.gradle.kts
jib {
    from {
        image = "gcr.io/distroless/java21-debian12"   // or eclipse-temurin:21-jre
        // In CI, pin by digest: "...@sha256:<digest>"
    }
    to { image = "registry.example.com/orders:$imageTag" }   // semver + short sha, immutable
    container {
        user = "65532:65532"                          // distroless nonroot
        ports = listOf("8080")
        jvmFlags = listOf("-XX:MaxRAMPercentage=75.0")
    }
}
```

The Dockerfile route keeps the same layering by hand: Spring Boot's `bootJar` is already layered, so
extract it in the build stage — `java -Djarmode=tools -jar app.jar extract --layers` on Boot 3.3+,
`java -Djarmode=layertools -jar app.jar extract` before that — and `COPY` each layer separately; a
Ktor build produces the same shape from `installDist` (the `application` plugin) or a `shadowJar`.

1. **Pin the base image by digest, not by tag.** `eclipse-temurin:21-jre` is a moving target, and a
   rebuild of one commit that produces a different runtime cannot reproduce an incident.
2. **Non-root, and no shell if you can take it.** A distroless image has no shell: a whole class of
   container escape goes, and so does `exec`-ing in to debug. Keep a debug-tagged variant instead.
3. **`-XX:MaxRAMPercentage`, not `-Xmx`.** The container's memory limit is the fact; a hard-coded
   heap either wastes the limit or is killed by it when the limit changes.
4. **Layer ordering is the whole build-time story.** Dependencies change rarely and classes change
   every commit; a single fat-jar layer re-pushes 80 MB for a one-line fix.
5. **The tag is immutable and carries the commit** (`release-ops` `## Versioning`) — that is what
   makes "roll back" a deploy of a tag that still exists.

## Probes

| Probe | Answers | A failure means |
|---|---|---|
| liveness | is this process still able to make progress at all | the orchestrator kills and restarts the container |
| readiness | can it serve a request **right now** — database reachable, migrations done, pools warm | it is taken out of the load balancer, and left running |
| startup | has a slow JVM boot finished | the other two are held off, so a slow start is not a restart loop |

```properties
# Spring Boot
management.endpoint.health.probes.enabled=true
management.endpoints.web.exposure.include=health,prometheus
```

That exposes `/actuator/health/liveness` and `/actuator/health/readiness`. Ktor has no equivalent, so
the routes are hand-written and the gate is explicit:

```kotlin
val ready = AtomicBoolean(false)

routing {
    get("/health/live") { call.respond(HttpStatusCode.OK) }
    get("/health/ready") {
        if (ready.get()) call.respond(HttpStatusCode.OK)
        else call.respond(HttpStatusCode.ServiceUnavailable)
    }
}

// An init container or a Job already migrated (see Migrations on Deploy).
// A replica verifies the schema it was built against; it never migrates.
val schema = Flyway.configure().dataSource(ds).load().info().current()?.version
ready.set(schema != null && schema >= MigrationVersion.fromVersion(EXPECTED_SCHEMA))
```

1. **Liveness must not touch a dependency.** A liveness probe that queries the database restarts
   every replica the moment the database blinks, turning a brief outage into a full restart storm.
2. **Readiness must touch exactly the dependencies it needs to serve** — and nothing else. A
   readiness check on an optional downstream removes a healthy replica from rotation.
3. **Readiness gates on the migration having run — checked here, never run here**
   (`## Migrations on Deploy`). The replica compares the schema version it finds against the one its
   build expects; serving against a half-migrated schema is worse than not serving.
4. **Use the startup probe for slow boots.** A JVM with a large context that takes 40 s to start
   under a 30 s liveness probe never becomes live, and the symptom looks like a crash loop.
5. **Probe endpoints stay cheap and unauthenticated** on the internal port; a probe that allocates or
   locks becomes the thing that fails under load.

## Configuration

- **Environment variables over files** — one image, N environments, and anything that differs
  between staging and production is a variable, never a rebuild.
- **Spring** binds them by relaxed naming: `APP_ORDERS_MAX_BATCH` reaches `app.orders.max-batch`,
  typed through `@ConfigurationProperties` (`di-spring` `## Properties`), which also gives startup
  validation.
- **Ktor** reads `ApplicationConfig` (`environment.config`) with `${?ENV_VAR}` substitution in
  `application.conf`, and the same values are readable in tests without a process.
- **Secrets come from the platform's store** — Kubernetes Secrets, Vault, a cloud secret manager —
  mounted as environment variables or files at run time. Never baked into the image, never in the
  repository; the build-time half of the same rule is `release-ops` `## Secrets in CI`.

1. **Fail at startup on a missing required value**, not on the first request that needs it. A typed
   binding with no default does this for free.
2. **Profiles select behaviour, not credentials.** `application-prod.yml` may name a strategy; the
   moment it holds a password, the image is environment-specific and the twelve-factor property is
   gone.
3. **A configuration change is a deploy.** Restarting to pick up a value is fine and predictable;
   hot-reloading configuration is a feature with its own failure modes — take it only when the
   restart genuinely cannot be afforded.
4. **Log the effective configuration once at startup, with secrets redacted.** Half of the "but it
   works in staging" incidents end at that one line.

## Shutdown

The order is **SIGTERM → stop accepting new work → drain in-flight → close pools and clients → exit.**

```properties
# Spring Boot
server.shutdown=graceful
spring.lifecycle.timeout-per-shutdown-phase=30s
```

Ktor stops the engine explicitly — `embeddedServer(...).stop(gracePeriodMillis, timeoutMillis)` from
a shutdown hook, with the `ShutDownUrl` plugin only where an operator-triggered stop is wanted. On
Kubernetes, `terminationGracePeriodSeconds` must exceed the drain window, and a `preStop` sleep of a
few seconds covers the gap between the pod leaving the endpoints list and the load balancer noticing.

1. **The grace period is a budget the platform enforces.** When the drain outlasts
   `terminationGracePeriodSeconds` the process is SIGKILLed mid-request — set the platform's number
   above the framework's, not the other way round.
2. **`preStop` exists because deregistration is not instant.** Without it, traffic keeps arriving for
   a second or two after the server stopped accepting — those requests are the 502s on the deploy graph.
3. **In-flight is not the same as queued.** Background work — a consumer loop, a scheduled job — has
   its own drain: cancel the application scope and await it (`concurrency-coroutines`).
4. **Close pools last, after the work that uses them.** A connection pool closed while a request is
   still running turns a clean shutdown into an error burst in the logs.
5. **A shutdown path nobody exercises does not work.** Send SIGTERM in an integration test, or in
   staging on purpose, and watch for dropped requests.

## Migrations on Deploy

The discipline — expand/contract, additive first, never a rename in one deploy — is
`persistence-migrations`, and this section does not restate it. What deploy orchestration adds:

1. **Migrations run exactly once per deploy, from one place**: an init container, a Kubernetes `Job`,
   or a pre-deploy pipeline step. One thing runs them, one log to read, one exit code to gate on.
2. **Never from parallel replicas.** Flyway and Liquibase take a lock, which makes concurrent starts
   *safe* but not *correct*: N replicas serialize behind it, the slowest start becomes the rollout's
   timeout, and a failed migration becomes a pod crash-loop instead of a failed job with a stack
   trace at the top of the pipeline.
3. **Readiness gates on migration-done** (`## Probes`), so no replica serves against a schema that is
   half-changed.
4. **Expand, deploy, then contract in a later deploy.** During a rolling update old and new code run
   against the same schema at the same time; the expand step is what makes that legal, and the
   contract step is what makes it temporary (`persistence-migrations` `## Zero-Downtime`).
5. **Failure stops the rollout; it does not roll the schema back.** The previous image has to keep
   running against the migrated schema — which is why the expand step is additive, and why a
   destructive one removes the option to stop.
6. **A long backfill is not a migration step.** It is a job you can watch, throttle and stop, run
   after the deploy that added the column.

## Observability

| Signal | Take |
|---|---|
| metrics | Micrometer with `micrometer-registry-prometheus`, scraped at `/actuator/prometheus`, or Ktor's `MicrometerMetrics` plugin on a route of its own |
| traces | OpenTelemetry — the `opentelemetry-javaagent` for zero-code instrumentation, or the Micrometer Tracing bridge when the code already creates spans |
| logs | structured JSON, one object per event, with a request id — `logstash-logback-encoder` plus MDC |

1. **RED per endpoint**: rate, errors, duration. Three series answer most incident questions, and
   Micrometer's HTTP metrics give them without new code.
2. **One request id, in the MDC, propagated as W3C `traceparent`**, so a log line and a trace can be
   joined without guessing at timestamps.
3. **No PII in logs, and this is a release gate, not a style preference** — logs leave the process and
   land in a third party's index. The redaction rule is `error-architecture` `## Logging and PII`.
4. **Cardinality is what kills a metrics backend.** A user id, an order id or a raw path as a tag
   creates a series per value; template the path (`/orders/{id}`) and keep identifiers in the traces and logs.
5. **A health endpoint is not a metric.** Alert on the RED series and on saturation; alerting on the
   probe only tells you what the orchestrator already acted on.

## Rollout

| Strategy | Take when |
|---|---|
| rolling | the default: cheapest, no extra environment, requires that version N and N-1 can run together — which expand/contract already guarantees |
| blue-green | the cutover must be atomic and instantly reversible, and two full environments are affordable |
| canary | the failure mode is statistical — latency, error rate, a business metric — and there are automated gates to compare against |

1. **Rollback is deploying the previous tag**, which works only because the tag is immutable
   (`release-ops` `## Versioning`) and the schema is still compatible with it.
2. **Behaviour changes ride a flag, not a deploy** (`release-ops` `## Feature Flags`). A flag flips
   in seconds and needs no rollout; a deploy takes minutes and restarts everything.
3. **Database changes are decoupled from the rollout by expand/contract**, so the rollout never has
   to be atomic with a schema step.
4. **A canary with no metric gate is a slow rolling update.** Name the comparison and the threshold
   before starting, or the canary is just the first pod.
5. **A rollout nobody watches is a deploy with extra steps.** Name the observation window and who
   holds it — halting early is the cheapest action there is, and only works if someone is looking.

## Fragmentation

**`Platform fragmentation` — the platform's answer to core's key, for a server: skip the +20%–30%
delta.** The runtime matrix is one pinned JDK in one image, running the same way in every
environment, and the OS underneath it is the base image's. Apply the delta only when the service is
genuinely distributed into a matrix the team does not control — an on-premise build the customer runs
on their own JVM, or a library published across several JVM versions — and then it belongs to that
distribution, not to the deploy.

## Common Mistakes

1. **Migrations on application startup, in every replica.** They serialize behind the lock, the
   rollout times out, and a failure surfaces as a crash-loop instead of a job you can read.
2. **A liveness probe that checks the database.** A three-second database hiccup restarts the whole
   deployment, and the restart storm outlasts the hiccup by an order of magnitude.
3. **Configuration baked into the image**, one image per environment. The artifact tested in staging
   is then not the artifact that runs in production, which was the point of building an image.
4. **No graceful shutdown.** Every deploy drops the in-flight requests, and the error spike on the
   dashboard is read as "deploys are risky" rather than as a missing `preStop` and thirty seconds.
5. **`-Xmx` guessed, or no heap setting at all.** The container's limit and the JVM's heap disagree,
   and the pod is OOM-killed under exactly the load it was sized for.
6. **A mutable tag — `latest`, or a branch name.** Rollback resolves to whatever was pushed last, so
   the one operation that must be deterministic is the one that is not.
7. **Free-text logs.** Every incident starts with someone writing a regex; a JSON object with a
   request id is queryable from the first minute.
8. **A metric tagged with a user id.** The dashboard works for a week and then the metrics backend
   falls over, and the fix is to delete the series everyone now depends on.
9. **The contract step in the same deploy as the code that stopped using the column.** During the
   rolling window the old replicas are still reading it, and the zero-downtime deploy takes the
   service down.
