---
name: pkg-gradle-modules
description: "Use when deciding whether and how to split a Kotlin build into Gradle modules — the archetypes (app, feature, core, data, api-contract, test-fixtures), api vs implementation, the version catalog, convention plugins in build-logic, module graph rules, and build performance (configuration cache, parallel, build cache). Also the multi-repository composite build, in outline."
---

# Gradle Modules

A Gradle module is the only architectural boundary the Kotlin compiler enforces on its own: `internal`
stops at it, and a dependency the build file does not declare cannot be imported. This skill decides
whether the build gets split at all, which archetype each module is, what it may depend on, and how
the module files stay short enough that adding the tenth one is a ten-line file. What lives *inside* a
multiplatform module is `pkg-kmp-source-sets`.

> **Related skills:**
> - `pkg-kmp-source-sets` — the source-set layout inside a module that declares more than one target
> - `arch-clean` — the `:domain` / `:data` / `:feature:*` split these archetypes generalize, and its four build files
> - `arch-hexagonal` — the `:core` / `:adapters:*` / `:app` shape on a server, and the direction its build files enforce
> - `di-composition-root` — why `:app` is the only module allowed to name every other one
> - `di-hilt` — which modules get the plugin and the KSP line, and which must be left without them
> - `net-openapi` — the module that owns a generated source tree, and why nothing `api`-exposes it
> - `release-ops` — the CI lanes that run against this graph, and where the remote build cache lives
> - `architecture-choice` — the compass that reaches this skill once the team or the build time says split

## When to Use

- A single-module build has started to hurt: two people editing the same module, or a one-line change
  costing a full rebuild
- A new module is about to be created and nobody has said what kind of module it is
- User asks "should we modularize", "`api` or `implementation`", "where do versions go", "what is
  `build-logic`", "why is our build slow", "can `:feature:cart` call `:feature:checkout`", "`buildSrc`
  or an included build"
- Review finds a `:feature` naming another `:feature`, a version string typed into a
  `build.gradle.kts`, or a module file that repeats forty lines the module next door also has
- Two repositories are being co-developed and someone proposes publishing a snapshot on every change

Not for the layer boundaries themselves — which module a use case belongs in is `arch-clean` or
`arch-hexagonal`, and this skill starts once the answer is "its own module". Not for the source sets
inside a multiplatform module (`pkg-kmp-source-sets`).

`references/detailed-guide.md` lies beside this file; its `## Contents` names the sections — read only the ones the table points to.

## When To Load The Reference

| Need | Reference section |
|---|---|
| The six modules every later section builds against | `The Build It Wires` |
| `settings.gradle.kts`, the included build, where the catalog is declared | `Settings and the Included Build` |
| The `build-logic` build file, `kotlin-dsl`, and registering plugin ids | `The build-logic Build File` |
| The Android conventions as `Plugin<Project>` classes, and the helper they share | `Convention Plugins` |
| The same thing as a `*.gradle.kts` script named after its id | `Precompiled Script Plugins` |
| A catalog with `[versions]`, `[libraries]`, `[bundles]`, `[plugins]` | `The Version Catalog` |
| One build file per archetype, with only the lines that archetype may have | `Module Build Files` |
| A test that fails the build when a feature names another feature | `Enforcing the Graph` |
| The performance properties and what each one buys | `gradle.properties` |
| Wiring a sibling repository in without publishing | `Composite Build` |
| Fakes and builders shared with consumers without shipping them | `Test Fixtures` |

## When to Modularize

**Not yet** is the right answer for one developer and a build under thirty files: a second module
costs a build file, a dependency decision and a visibility decision, and buys a boundary nobody is
crossing. Four signals make it worth it, and each buys something different:

| Signal | What splitting buys |
|---|---|
| Two or more developers editing the same files | Ownership: a module is the unit a person or a team can hold |
| A one-line change triggers a long rebuild | Incremental compilation, which stops at the module boundary |
| A rule keeps being argued with in review | `internal` and an undeclared dependency, checked by the compiler |
| A second app, a CLI or a server wants the same code | A consumable unit rather than a copied package |

1. **Compile time is the measurable one.** Kotlin's incremental compiler recompiles within the module
   that changed and then recompiles its consumers as far as the ABI change reaches; a change in `:app`
   recompiles `:app` alone, because nothing depends on it. Push the code that changes hourly *down*
   the graph and the code that changes yearly *up*, and the hot module stays small.
2. **`internal` is the enforcement, and it is module-scoped.** An `internal` declaration is visible to
   the whole compilation unit — one module's `main` source set, plus that module's own tests — and to
   nothing else. Inside a single module, `internal` between packages says nothing at all.
3. **Parallel execution needs a wide graph, not a deep one.** Ten modules in a chain build one at a
   time; ten modules hanging off one `core` build together. Depth is what costs wall-clock time.
4. **Splitting is not free.** Each module is a build file, an `api`/`implementation` decision and a
   line in `settings.gradle.kts`. A `data class` that moves across a boundary also becomes unstable to
   the Compose compiler unless the new module applies that compiler too (`compose-state`) — a module
   split that made a screen recompose is the surprise nobody plans for.
5. **Split along a boundary that already exists.** A layer, a feature or a team. Splitting to hit a
   module count produces modules whose names nobody can explain a month later.

## Archetypes

Six kinds of module, and the fourth column is the whole design. A module that wants a dependency
outside its row is either the wrong archetype or the graph is wrong.

| Archetype | Naming | Holds | May depend on |
|---|---|---|---|
| app | `:app` | the entry point, the composition root, the manifest or `main()` | everything |
| feature | `:feature:orders` | screens, ViewModels, feature-local navigation | core, data, api-contract |
| core | `:core:ui`, `:core:model` | design system, shared utilities, shared domain types | nothing internal |
| data | `:data:orders` | DTOs, DAOs, API services, mappers, repository implementations | core, api-contract |
| api-contract | `:api:orders` | interfaces and DTOs two modules must agree on; no implementation | nothing |
| test-fixtures | the `testFixtures` source set of the module it fixtures | fakes, builders, test dispatchers | the module it fixtures |

The `feature → data` edge is in the table because a build may legitimately use it, but a Clean layout
does not: there a feature depends on interfaces that live in `core` and `:app` binds the
implementation (`arch-clean`), so the edge belongs only to a build with no separate `:app`-side
composition root.

1. **Never feature → feature.** The moment `:feature:cart` names `:feature:checkout`, both rebuild
   together, neither can ship alone, and the next arrow closes a cycle. Route through an
   `api-contract` module both depend on, or hoist the shared piece into `core`.
2. **`:app` is the only module that knows every feature**, because it is where the graph is assembled
   and the routes are registered (`di-composition-root`).
3. **`core` depends on no module of this build.** External libraries yes; a sibling module never. The
   first `implementation(project(...))` in a core module is the moment it stopped being one.
4. **`core` is a name, not a bucket.** `:core:designsystem`, `:core:model`, `:core:datetime` — narrow
   and named for what they hold. `arch-clean` refuses a `:core` in its three-module layout for exactly
   this reason: a module everything depends on has no dependency rule left to enforce.
5. **The archetypes name a shape; they do not rename the modules a pattern already gave you.**
   `arch-clean`'s `:domain` is a core module here and its `:data` is a data module; `arch-hexagonal`'s
   `:core` is one too, and its `:adapters:*` are data modules with a different name. Keep the pattern's
   names.
6. **`api-contract` exists to break a cycle**, and that is its only job. If it grows an
   implementation, it is a core module wearing the wrong name.
7. **test-fixtures is a source set before it is a module.** `java-test-fixtures` publishes a
   `testFixtures` source set from the module that owns the types; a separate `:core:testing` module is
   right only for helpers no single module owns — a test dispatcher rule, a shared fake clock.

## api vs implementation

1. **`api` only when the type appears in your own public signatures** — a return type, a parameter, a
   supertype, a public property. Then the consumer needs it on its compile classpath, and `api` is
   what puts it there. `arch-clean`'s `:data` declares `api(project(":domain"))` for exactly that
   reason: it hands back domain types.
2. **`implementation` for everything else**, which is nearly everything. It keeps the dependency off
   the consumer's compile classpath, so a change inside it does not recompile consumers, and compile
   avoidance keeps working. An `api` used out of habit gives every downstream module the whole
   transitive classpath and the recompiles that come with it.
3. **`compileOnly` for what is present at compile time and supplied at runtime** — an annotations-only
   artifact, an API the container provides. It reaches no consumer and no runtime classpath.
4. **`testImplementation` and `testFixtures(project(":x"))` for test-only edges.** A fake that arrives
   through `implementation` ships in the production artifact.
5. **The rule is checkable.** If deleting `api` and building leaves consumers compiling, it was
   `implementation`. That is the whole test, and it costs one build.

## Version Catalog

`gradle/libs.versions.toml` is the one place a version is written. Four tables, one accessor rule:

```toml
[versions]
kotlin = "2.2.20"
ktor = "3.0.3"

[libraries]
ktor-client-core = { module = "io.ktor:ktor-client-core", version.ref = "ktor" }
ktor-client-okhttp = { module = "io.ktor:ktor-client-okhttp", version.ref = "ktor" }
ktor-client-content-negotiation = { module = "io.ktor:ktor-client-content-negotiation", version.ref = "ktor" }
ktor-serialization-json = { module = "io.ktor:ktor-serialization-kotlinx-json", version.ref = "ktor" }

[bundles]
ktor-client = ["ktor-client-core", "ktor-client-okhttp", "ktor-client-content-negotiation", "ktor-serialization-json"]

[plugins]
kotlin-jvm = { id = "org.jetbrains.kotlin.jvm", version.ref = "kotlin" }
```

1. **Accessors replace `-` with `.`.** `ktor-client-core` is `libs.ktor.client.core`, and
   `libs.bundles.ktor.client` pulls the whole bundle. Plugins are `alias(libs.plugins.kotlin.jvm)` in
   a `plugins { }` block — the `alias(...)` form is what a plugin entry is for, and no version string
   goes beside it.
2. **`[bundles]` for artifacts that always move together** — a client and its serializer, a test
   framework and its assertions. One line in the module file instead of five that drift apart.
3. **A version string in a `build.gradle.kts` defeats the catalog** for that artifact: it will be the
   one left behind on the next upgrade, and it is invisible to the dependency-update tooling.
4. **`versionCatalogs { create("libs") }` in `settings.gradle.kts` is only for a non-default name or a
   catalog published as an artifact.** A file at `gradle/libs.versions.toml` is picked up with no
   declaration at all.
5. **`build-logic` does not get the `libs` accessors for free.** A precompiled script plugin can
   declare the same catalog in its own settings file; a binary plugin reads it through
   `VersionCatalogsExtension` (see the reference). This is the one gotcha in the whole setup.

## Convention Plugins

The point is that a module file says only what is *different* about that module. Everything shared —
SDK versions, the JVM target, compiler arguments, the test dependencies, lint — moves into a plugin
the module applies by id:

```kotlin
// :feature:orders/build.gradle.kts — the whole file
plugins {
    id("orders.android.feature")
}

android { namespace = "com.example.feature.orders" }

dependencies {
    implementation(project(":core:designsystem"))
    implementation(project(":api:orders"))
}
```

1. **`build-logic` as an included build, never `buildSrc`.** Since Gradle 8.0 `buildSrc` builds like
   an included build — cacheable and parallel — so the old cost story is out of date. What survives is
   the one that matters: its jar is on the classpath of *every* build script in the build, so any
   change to it recompiles all of them. An included build reaches only the modules that apply one of
   its plugin ids.
2. **Name the plugins `<project>.<target>.<archetype>`** — in a build whose root project is
   `orders`: `orders.android.application`, `orders.android.library`, `orders.jvm.library`,
   `orders.android.feature`. The dotted id reads as a coordinate, sorts sensibly, and the project
   segment is what keeps it from colliding with a published plugin id.
3. **Precompiled script plugins and binary plugins are both fine.** A file named
   `orders.jvm.library.gradle.kts` *is* the plugin id and needs no registration — shortest
   path, and the right default. A `Plugin<Project>` class registered in `gradlePlugin { }` buys typed
   access to extensions, shared helper functions and a plugin you can unit-test; take it when the
   conventions grow past a screenful.
4. **A convention plugin applies plugins and sets defaults; it does not declare feature
   dependencies.** The moment it adds `implementation(project(":core:analytics"))`, every module that
   applies it has that edge, and the graph is no longer readable from the build files.
5. **One plugin per archetype, not per module.** Four or five plugins for a fifty-module build is the
   healthy ratio; a plugin used once is a build file with extra steps.

## Graph Rules

1. **The graph is a DAG, and Gradle only half-enforces it.** A project cycle does fail the build, but
   as a circular-task-dependency error at execution time — a message about tasks, thrown long after
   the design mistake was made.
2. **Four rules carry the whole design:** never feature → feature; `:app` alone knows every feature;
   `core` names no module of this build; `api-contract` names nothing.
3. **Enforce them with a test, not with review.** A Konsist `assertArchitecture` block, an ArchUnit
   rule on the JVM, or a Gradle task that walks `project.configurations`, keeps the
   `ProjectDependency` entries and asserts the allowed pairs. The reference has the Gradle-task form,
   which needs no extra dependency and runs in CI beside the unit tests (`release-ops`).
4. **The rule test belongs in the build, not in a document.** A dependency added in a hurry at 18:00
   is caught by a red build or it is not caught.
5. **A module graph picture is a diagnosis, not a rule.** `./gradlew :app:dependencies` and the
   project-dependency plugins show what is; the test says what is allowed.
6. **`internal` by default in every module.** A `public` class in a module is a promise to every
   consumer, and the archetype rules above only constrain module edges — not what leaks across one.

## Build Performance

```properties
# gradle.properties
org.gradle.configuration-cache=true
org.gradle.parallel=true
org.gradle.caching=true
org.gradle.jvmargs=-Xmx4g -XX:+UseParallelGC -XX:MaxMetaspaceSize=1g
kotlin.incremental=true
```

1. **The configuration cache is the largest single win** and the one that needs work: it serializes
   the configured task graph and skips the configuration phase entirely on a rerun. It breaks when a
   task reaches for `project` at execution time — capturing `Project` in a task action, reading
   `project.buildDir` or `System.getenv` outside a `Provider`. The fix is a `Property`/`Provider` on
   the task; disabling the cache to silence one plugin gives back seconds on every build in the repo.
2. **`org.gradle.parallel=true` pays exactly as much as the graph is wide** (see When to Modularize,
   rule 3), and the build cache pays most on CI, where nothing is incremental — a local cache for
   developers, a remote node for CI (`release-ops`).
3. **`org.gradle.jvmargs` sizes the daemon, not your app.** Too small and the build dies in GC on a
   large module; changing it starts a second daemon, so pick a value and keep it in the file rather
   than in someone's shell.
4. **KSP, never kapt.** kapt generates Java stubs for every source file in the module before the
   processor runs; KSP reads the Kotlin declarations directly. Every processor this platform names has
   a KSP form (`di-hilt`, `persistence-room-sqldelight`).
5. **`kotlin.incremental=true` is the default**, and worth writing down: someone always turns it off
   while chasing a stale-build ghost and never turns it back on.
6. **Measure before changing anything.** `./gradlew <task> --scan` publishes a timeline that names the
   slow task and the cache misses; `gradle-profiler` repeats a scenario enough times to tell a real
   change from noise.

## Composite Builds

Two repositories co-developed at once — an app and a library it drives — do not need a snapshot on
every commit. `includeBuild` substitutes the local checkout for the published coordinate:

```kotlin
// settings.gradle.kts
includeBuild("../shared-lib") {
    dependencySubstitution {
        substitute(module("com.example:shared")).using(project(":"))
    }
}
```

1. **The substitution block is only needed when the coordinates do not match.** When the included
   build's `group` and `name` already equal the coordinate you depend on, Gradle substitutes it
   automatically and the block is noise.
2. **The dependency line does not change.** Module files keep `implementation(libs.shared)`; only the
   settings file knows the difference, so the composite wiring is one line to add and one to remove.
3. **Use it for co-development, not as the shipping shape.** CI must still build against the published
   artifact, or the version everyone else resolves is never exercised.
4. **The cost is one Gradle build per included build**, each with its own configuration phase. Two is
   comfortable; a composite of six is slower than publishing.
5. **The wiring is scriptable**, and a later command automates it for a new workspace — this section
   is the shape it produces, so a hand-written one matches.

## Common Mistakes

1. **`api` on everything** — usually pasted once and copied thereafter. Every downstream module now
   recompiles on any transitive ABI change, compile avoidance is off, and nobody can tell which edges
   were deliberate. `implementation` unless the type is in your own signatures.
2. **`:feature:cart` depending on `:feature:checkout`** — the two ship together forever, and the next
   arrow between features closes a cycle Gradle reports as a task error. The shared piece is an
   `api-contract` module or it belongs in `core`.
3. **A `:common` or `:core` module everything lands in.** It depends on nothing and everything depends
   on it, so every change rebuilds the world and no rule constrains what may go in. Split it by what
   it actually holds, and name each piece.
4. **`buildSrc` for the conventions.** Its jar sits on every build script's classpath, so a one-line
   edit there recompiles every build script in the repo; `build-logic` is paid for only by the modules
   that apply one of its ids. (`buildSrc` has built like an included build since Gradle 8.0 — that
   half of the old argument is gone; this half is not.)
5. **A version string in a module's `build.gradle.kts`.** It is the one the upgrade misses, the one
   that resolves to a different version than the catalog's, and the reason two modules link two copies
   of the same library.
6. **Turning the configuration cache off because one plugin fails it.** The failing plugin is usually
   one `Provider` away from working, or has a newer version that already does; the build pays for that
   decision on every invocation, on every machine, forever.
7. **`allprojects { }` or `subprojects { }` in the root build file.** It configures modules that have
   not been evaluated yet, is invisible from the module it affects, and is the first thing the
   configuration cache and isolated project execution reject. Convention plugins are the replacement.
8. **Test fixtures copied into every module's test source set.** Three drifting copies of the same
   fake, and the one you fixed is not the one the failing test used. Publish them once from the module
   that owns the types with `java-test-fixtures`.
9. **A module per class.** Fifty build files, a settings file nobody reads, and a configuration phase
   longer than the compilation it was meant to shorten. A module needs a reason from the table in
   When to Modularize.
10. **Skipping the graph test because "everyone knows the rules".** The rules survive exactly until
    the first hurried Friday; the test is fifteen lines and it never gets tired.

## Checklist

Creating a module:

- [ ] Archetype picked from the table, and the module named for it (`:feature:*`, `:core:*`, `:data:*`)
- [ ] The matching convention plugin applied — the build file is roughly ten lines
- [ ] Only dependencies the archetype's row allows, each one `implementation` unless a type of it
      appears in this module's own public signatures
- [ ] No version string in the file: every artifact through `libs.*`, every plugin through
      `alias(libs.plugins.*)`
- [ ] Everything `internal` unless a consumer needs it
- [ ] At least one test in the module, and fixtures shared through `testFixtures` rather than copied
- [ ] The module added to `settings.gradle.kts`
- [ ] The graph-rule test still green, and `--configuration-cache` still reused on a second run
