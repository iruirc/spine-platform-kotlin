---
name: net-openapi
description: "Use when an API has (or should have) an OpenAPI spec — consuming it in a Kotlin client (openapi-generator kotlin, Fabrikt) behind an adapter, or serving it from a Kotlin server code-first (springdoc, Ktor OpenAPI plugin, http4k-contract) or contract-first (generated server stubs). Covers generator choice, the adapter pattern, generated-code hygiene, and contract tests."
---

# OpenAPI in a Kotlin Build

A spec is worth having only when something mechanical depends on it: a client generated from it
rather than typed out, a server whose responses are checked against it, a CI job that fails when it
changes in a way consumers cannot absorb. This skill picks the generator, puts the generated code
behind the interface `net-architecture` already defines, and names what has to run for the spec to
stay true — the boundary itself and the client underneath it are the neighbours' business, not this
one's.

> **Related skills:**
> - `net-architecture` — the `ApiClient` interface the generated client is wrapped in, and the middleware stack it still sits inside
> - `net-http-clients` — the client and serializer the generator's `library` option has to agree with
> - `arch-layered` — the entry-point layer of a served spec, and where its DTOs stop
> - `arch-hexagonal` — the generated client as an outbound adapter, the generated server interface as an inbound one
> - `error-architecture` — turning an undocumented status or a parse failure into one domain error
> - `pkg-gradle-modules` — the module that owns the generated tree, and why nothing `api`-exposes it
> - `release-ops` — publishing the spec as a versioned artifact, and the CI lane that diffs it

## When to Use

- An API the project consumes publishes an OpenAPI spec, or one is about to be written for an API it
  serves
- User asks "should we generate the client", "openapi-generator or Fabrikt", "springdoc or
  contract-first", "do we commit generated code", "where do contract tests live", "how do I find out
  the API changed before production does"
- A hand-written client has drifted from an API that does publish a spec, and the symptom is a field
  that silently arrives null
- Review finds a generated model imported above `:data`, a checked-in generated tree with no
  regeneration step, or a hand edit inside one
- A service serves Swagger UI over a spec file nobody has touched since it was added

Not for the boundary the generated client hides behind, the middleware order, retry or token refresh
— all `net-architecture`. Not for choosing the client and serializer themselves
(`net-http-clients`). Not for an API with no spec and no intention of writing one: codegen without a
source of truth is hand-writing with extra steps.

## Consuming a Spec

| Generator | Emits | Take it when |
|---|---|---|
| `openapi-generator`, Gradle plugin `org.openapi.generator`, `generatorName = "kotlin"` | models plus a client over the library you name: `library = "jvm-retrofit2" \| "jvm-okhttp4" \| "jvm-ktor" \| "multiplatform"`, with `serializationLibrary = "kotlinx_serialization"` | the default — it covers every client row of `net-http-clients`, including the KMP one, and the whole config is Gradle |
| Fabrikt, Gradle plugin `com.cjbooms.fabrikt` | Kotlin-first models, optionally a client and Spring controller interfaces; JVM-only | the models are what matter and their shape is what you will read — Fabrikt emits idiomatic Kotlin (data classes, sealed `oneOf`, real nullability) rather than a Kotlin rendering of a Java template |
| No generator | — | the spec is a handful of endpoints, or it lies about the API often enough that the generated client would be a phantom |

1. **The `library` is not a new decision.** It has to be the client `net-http-clients` already chose
   for this build. `library = "jvm-okhttp4"` in a Retrofit project is a second client: a second
   connection pool, a second interceptor stack, and one of them without the auth header.
2. **KMP has two paths and no third.** `openapi-generator` with `library = "multiplatform"` (Ktor and
   kotlinx.serialization underneath, `commonMain`-safe), or Fabrikt models with a hand-written Ktor
   client over them. The `jvm-*` rows do not compile in `commonMain`, and Fabrikt alone does not
   leave the JVM (`pkg-kmp-source-sets`).
3. **The generated `Api` is not the project's `ApiClient`.** An adapter in `:data` implements the
   interface `net-architecture` defines and maps generated models to the project's own DTOs; no
   generated type crosses that file in either direction.
4. **The generator emits calls, not policy.** Logging, auth, retry and timeouts stay in the
   middleware stack around the underlying client — the generated code is one more caller of it, and
   a generator option that adds a header is a rule written where nobody will look for it.

```kotlin
// :data — the only file that imports the generated package.
import com.example.api.generated.api.OrdersApi as Generated
import com.example.api.generated.model.Order as GeneratedOrder

internal class GeneratedOrdersApi(private val generated: Generated) : OrdersApi {

    override suspend fun orders(cursor: String?): Page<OrderDto> {
        val page = generated.listOrders(cursor = cursor)
        return Page(page.items.map { it.toDto() }, page.next)
    }

    override suspend fun order(id: String): OrderDto = generated.getOrder(id).toDto()

    override suspend fun place(draft: OrderDraftDto, idempotencyKey: String): OrderDto =
        generated.createOrder(draft.toGenerated(), idempotencyKey).toDto()
}

private fun GeneratedOrder.toDto() = OrderDto(id = id, total = total, placedAt = placedAt)
```

`OrdersApi`, `Page` and `OrderDto` are the project's, declared where `net-architecture` puts them.
The mapping looks redundant on the day it is written and stops being redundant the first time the
spec renames a field or adds one the domain does not want.

5. **Generated code is a build output, not a source file.** The generate task runs before compilation
   and its output is a source directory under `build/`, which is already ignored — so a stale
   generated tree cannot exist, and a review never contains ten thousand lines nobody read.
6. **The spec itself is committed**, or fetched at a pinned tag or content hash into the same place.
   A build that reads a live `/v3/api-docs` depends on somebody's staging deploy: it fails when that
   environment is down, and worse, it succeeds differently on two machines.

```kotlin
// :data/build.gradle.kts
plugins { alias(libs.plugins.openapi.generator) }   // pinned in the catalog, never a range

val generated = layout.buildDirectory.dir("generated/openapi")

openApiGenerate {
    generatorName.set("kotlin")
    inputSpec.set("$rootDir/specs/orders.yaml")     // committed beside the build
    outputDir.set(generated.map { it.asFile.path })
    apiPackage.set("com.example.api.generated.api")
    modelPackage.set("com.example.api.generated.model")
    generateApiTests.set(false)
    generateModelTests.set(false)
    configOptions.set(
        mapOf(
            "library" to "jvm-retrofit2",           // the client net-http-clients already chose
            "serializationLibrary" to "kotlinx_serialization",
        ),
    )
}

kotlin.sourceSets["main"].kotlin.srcDir(generated.map { it.dir("src/main/kotlin") })
tasks.compileKotlin { dependsOn("openApiGenerate") }
```

The last two lines are the whole wiring: the output is a source root, and compilation depends on the
task that fills it. Without the `dependsOn` the first clean build compiles against nothing and the
error names a missing package rather than a missing task.

## Serving a Spec

Two directions, and a service is on exactly one of them: either the code is the source and the spec
is derived from it, or the spec is the source and the interfaces are generated from it.

| Framework | Code-first | Contract-first |
|---|---|---|
| Spring Boot | `springdoc-openapi` (`org.springdoc:springdoc-openapi-starter-webmvc-ui`) reads the controllers and their annotations, serves the spec and Swagger UI | `openapi-generator` `generatorName = "kotlin-spring"` with `interfaceOnly = true` — generated `@RequestMapping` interfaces that hand-written controllers implement |
| Ktor | `io.ktor:ktor-server-openapi` and `io.ktor:ktor-server-swagger` **serve a spec file you maintain**; neither derives anything from the routing tree | the natural fit: `openapi-generator` `generatorName = "kotlin-server"` with `library = "ktor"`, or hand-written routes and a test that validates them against the spec |
| http4k | `http4k-contract` — the contract DSL *is* the spec: a route declares its lenses and the description renders from them | already contract-first by construction; there is no second direction to choose |
| Micronaut | `micronaut-openapi` — an annotation processor writes the spec at compile time | reachable through `openapi-generator`, but against the grain of a framework built on compile-time annotation processing |
| Quarkus | `quarkus-smallrye-openapi` — derives the spec from the endpoint annotations and serves it at `/q/openapi` | the same trade as Micronaut |

1. **Pick the direction once, per service, and write it down.** Code-first plus a hand-edited spec
   file in the repository is two sources of truth, and they part company in the first sprint.
2. **Code-first is honest only when the build produces the spec.** One that exists solely at a
   running instance's `/v3/api-docs` cannot be diffed, pinned or generated from; springdoc's Gradle
   plugin (`org.springdoc.openapi-gradle-plugin`, task `generateOpenApiDocs`) boots the application
   and writes the file, and a code-first project without that task has a page, not an artifact.
3. **Ktor's OpenAPI plugins serve, they do not derive.** `ktor-server-openapi` renders documentation
   from a spec file and `ktor-server-swagger` serves Swagger UI over one; nothing inspects the
   routes. On Ktor the file is written by a human, so either the spec generates the routes or a test
   keeps the two honest — there is no third state where it maintains itself.
4. **`interfaceOnly = true`, always.** Generate the interface and implement it in your own controller.
   Generating whole controllers leaves one of two futures: editing generated files, or never
   regenerating again.
5. **Contract-first is what a shared contract asks for** — the spec is reviewed before either side
   builds, and both sides generate from it. Code-first is right for a service with one consumer, or
   an API still being discovered as it is written.
6. **The generated interface's models are transport models.** They stop at the entry-point layer with
   every other request body; the service below sees domain types (`arch-layered`, `arch-hexagonal`).
7. **The spec is published like any other artifact** — a versioned file, a Maven publication, a
   tagged commit — and consumers pin a version rather than tracking a branch (`release-ops`).

## Contract Tests

The spec is the fixture. That is the whole reason to have one: a fixture written by hand agrees with
the code it was written beside and never with the API.

| Side | What runs | Against |
|---|---|---|
| client | tests against a stub driven from the spec — Prism (`prism mock`) answers the whole spec with nothing written, WireMock with `com.atlassian.oai:swagger-request-validator-wiremock` checks the stubs you did write, or an `openapi-generator` server stub | the spec version the client generated from |
| server | the MockMvc or RestAssured tests that already exist, plus a validating matcher — `swagger-request-validator-mockmvc`, `swagger-request-validator-restassured`, or `openapi4j` | the spec the service publishes |
| CI | `openapi-diff` or `oasdiff` between the base spec and the branch's | the previous spec |

```kotlin
// The spec validates the responses the existing tests already produce — no second suite.
private val spec = OpenApiInteractionValidator.createFor("specs/orders.yaml").build()

@Test
fun `placing an order matches the spec`() {
    mockMvc.post("/orders") { contentType = APPLICATION_JSON; content = draftJson }
        .andExpect { status { isCreated() } }
        .andExpect { match(openApi().isValid(spec)) }
}
```

1. **Server validation goes inside the suite that already runs.** A separate contract-test module is
   the module that gets skipped in the sprint it would first have failed.
2. **Prism and WireMock answer different questions.** Prism mocks every endpoint from the spec's
   examples or schemas with no stub written, which is the cheap breadth. WireMock costs a stub per
   case and buys the responses a spec never describes — a 500, a truncated body, a socket that hangs
   — which is where the retry and timeout rules are tested (`net-architecture`).
3. **Test the undocumented response.** Staging returns an HTML maintenance page under a 200 and the
   generated client throws a serialization failure, not an HTTP one; the adapter maps it like any
   other failure, and a test that never sees it lets the app crash instead (`error-architecture`).
4. **Both sides must name the same spec version.** A client generated from a tag and tested against
   the branch's spec proves nothing about what ships.
5. **Breaking-change detection is the producer's job and fails the producer's build.** `openapi-diff`
   and `oasdiff` both classify each change as breaking or compatible; the gate worth having is "a
   breaking change requires a version bump", not "no breaking changes ever".
6. **On http4k the server half is free.** The lens set that parses a request is the same one the spec
   renders from, so a route cannot document something it will not accept.

## Hygiene

1. **One package prefix for everything generated** — `com.example.api.generated`, with `apiPackage`
   and `modelPackage` beneath it. One import to grep for, and a rule a reviewer can apply without
   reading the mapping.
2. **`internal` where the generator allows it, a module boundary where it does not.** The Kotlin
   client generator emits public declarations and offers no visibility knob, so the isolation has to
   be structural: the generated tree lives in the module that owns the adapter, and dependants get it
   through `implementation`, never `api` (`pkg-gradle-modules`).
3. **Regenerate in CI and fail on the difference.** When the tree is a build output, the CI build
   already is that check. Checked in as a deliberate exception — an IDE that has to index it, a
   consumer with no generator on its path — CI runs the generate task and then `git diff --exit-code`
   over the generated directory; the cheap variant stores the spec's hash beside the tree and
   compares that instead.
4. **Never edit a generated file.** The edit survives until the next regeneration and no longer, and
   the bug it fixed returns in a release nobody connects to it. What changes is the spec, a config
   option, or — last — a template.
5. **`templateDir` only when the alternative is nothing at all.** A forked template is pinned to the
   generator's internal template layout, so the next bump does not fail the build, it silently
   produces different output. Fork the one `.mustache` file you must, record why in a line beside it,
   and re-diff it against upstream on every generator bump.
6. **Pin the generator version and treat the bump as a change.** Two versions produce two different
   clients from one spec, and the difference surfaces as a parse failure on the machine that had the
   other one.
7. **Generate only what is consumed.** `generateApiTests`, `generateModelTests` and the documentation
   flags emit files nobody reads, lengthen every build, and eventually fail for a reason that has
   nothing to do with the API.

## Common Mistakes

1. **A generated type above `:data`.** A model from `com.example.api.generated.model` in a ViewModel
   or a use case makes the spec the domain model: the next `operationId` rename is a hundred call
   sites, and a field the API happens to expose becomes a field the product now has. The adapter is
   where the two vocabularies meet, and it is one file.
2. **A `library` chosen independently of the project's client.** `jvm-okhttp4` generated into a
   Retrofit build is a second client with a second connection pool and a second interceptor stack,
   and the auth header is configured on exactly one of them.
3. **A checked-in generated tree with no regeneration check.** It is a build output wearing source
   code's clothes: the day someone regenerates locally on a different version, or edits it by hand,
   the build stays green and the client is wrong. Either it is under `build/`, or CI regenerates and
   diffs it.
4. **Editing a generated file.** It reviews like ordinary code, works until the next regeneration,
   and then the fix is gone with no failing test to say so.
5. **Swagger UI served over a spec nobody maintains.** `ktor-server-swagger` renders the file it is
   handed and derives nothing, so the documentation endpoint reports, with full confidence, whatever
   the API looked like in the sprint the file was last touched.
6. **A code-first spec that only exists on a running instance.** Nothing to diff, nothing to pin, and
   consumers generate from whatever staging happened to be serving on the morning they built.
7. **Hand-written JSON fixtures beside a spec that exists.** They encode what the code already does;
   the day the server adds a required field or changes a nullability, every test passes and the
   application fails to parse the first real response.
8. **`interfaceOnly = false` on `kotlin-spring`.** The generator writes the controllers, someone adds
   logic to them, and regeneration either destroys it or is quietly never run again.
9. **A spec fetched from a URL at build time, or an unpinned generator.** Both make the build a
   function of something outside the repository, and both fail in the way that costs most: not by
   breaking, but by producing a different client on a different day.
