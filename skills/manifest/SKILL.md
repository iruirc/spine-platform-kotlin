---
name: manifest
description: Platform manifest for kotlin-platform. Data, not instructions — the five tables spine-toolkit reads to bind roles, axes, heuristics, topics and entrypoints.
---

# Kotlin Platform Manifest

> This skill is **data**, not instructions. spine-toolkit reads the five tables below by
> invoking this skill; there is no procedure here to follow.

This is `kotlin-platform`'s manifest — the contract `spine-toolkit` documents and demonstrates
with its own reference platform manifest, filled in for Kotlin across three surfaces: Android,
Compose Desktop and JVM servers, with KMP as the way they share code. One plugin serves all
three (a project names exactly one platform), and what differs between them lives in the
`target` axis and in the roles fanned out on it. `tests/foundation/lib/manifest.test.bats` checks
this file structurally.

## Roles

Canonical core role → `plugin:agent`. A role fans out on `target` only where the tooling
differs — what the agent runs, not how it reasons. The bare row of a fanned-out role is the
fallback for a project whose `target` never resolved; it points at the agent of the common
tooling subset, so the degradation is "do less", never "do the wrong thing".

architect   = kotlin-platform:kotlin-architect
reviewer    = kotlin-platform:kotlin-reviewer
refactorer  = kotlin-platform:kotlin-refactorer
security    = kotlin-platform:kotlin-security
diagnostics = kotlin-platform:kotlin-diagnostics
init        = kotlin-platform:kotlin-init

developer[target=Android] = kotlin-platform:kotlin-compose-developer
developer[target=Desktop] = kotlin-platform:kotlin-compose-developer
developer[target=Server]  = kotlin-platform:kotlin-server-developer
developer[target=CLI]     = kotlin-platform:kotlin-server-developer
developer[target=KMP]     = kotlin-platform:kotlin-kmp-developer
developer                 = kotlin-platform:kotlin-kmp-developer

tester[target=Android] = kotlin-platform:kotlin-ui-tester
tester[target=Desktop] = kotlin-platform:kotlin-ui-tester
tester[target=Server]  = kotlin-platform:kotlin-server-tester
tester[target=CLI]     = kotlin-platform:kotlin-server-tester
tester[target=KMP]     = kotlin-platform:kotlin-kmp-tester
tester                 = kotlin-platform:kotlin-jvm-tester

validator[target=Android] = kotlin-platform:kotlin-ui-validator
validator[target=Desktop] = kotlin-platform:kotlin-ui-validator
validator[target=Server]  = kotlin-platform:kotlin-server-validator
validator[target=CLI]     = kotlin-platform:kotlin-server-validator
validator[target=KMP]     = kotlin-platform:kotlin-ui-validator
validator                 = kotlin-platform:kotlin-jvm-validator

## Axes

`ecosystem` is the one axis every platform must declare, and the one whose meaning
spine-toolkit fixes: it names the ecosystem this platform serves — `kotlin` here, not `jvm`,
because Android (ART) and Kotlin/Native are served too. Declared and reserved, not yet
consumed. Every other axis, and its allowed values, is this platform's own choice — the
catalog below is the source of truth for both `spine-toolkit:stack-detect` and the option
list the orchestrator renders. Values are proper nouns and are **never localized**: an option
list is rendered in the user's language, but the answer is matched back against this catalog,
so `Desktop`, `Server` and `Manual` stay as written in every language.

`target` carries what `ecosystem` cannot: the surface a build produces. `KMP` sits beside the
surfaces rather than as a separate axis because multiplatform is its own engineering situation
(`expect`/`actual`, source-set hierarchy), not a modifier on Android.

ecosystem    = kotlin
target       = Android, Desktop, Server, CLI, KMP
ui           = Compose, Views
async        = kotlinx.coroutines, RxJava, Reactor
di           = Hilt, Koin, Dagger, Spring, Manual
framework    = Spring Boot, Ktor, Micronaut, Quarkus, http4k, Clikt, kotlinx-cli
architecture = MVVM, MVI, Clean Architecture, Layered, Hexagonal
build        = Gradle KTS, Gradle Groovy, Maven, Amper
baseline     = API 21+, API 24+, API 26+, JVM 17, JVM 21
tests        = JUnit5, JUnit4, Kotest

## Heuristics

How `spine-toolkit:stack-detect` resolves axis values from repo signals: a `path` pattern flags
one or more axes as relevant, an `import`, `token` or `file` literal pins one specific value.
Kotlin's signals nest — a KMP build with an Android target carries both `kotlin("multiplatform")`
and `com.android.application` — so every `target` row names what must be present **and** what
must be absent. Nothing here depends on the order the rows are read in.

token: `kotlin("multiplatform")` anywhere in the build                                        → target=KMP
token: `com.android.application` or `com.android.library`, no `kotlin("multiplatform")`      → target=Android
token: `compose.desktop.application`, no Android plugin, no `kotlin("multiplatform")`         → target=Desktop
token: `org.springframework.boot`, `io.ktor.plugin`, `io.micronaut.application` or `io.quarkus`, no Android, Desktop or multiplatform plugin → target=Server
token: `application` plugin with `mainClass`, plus `clikt` or `kotlinx-cli`, no server framework plugin → target=CLI
token: an Android or Desktop plugin AND a server framework plugin in one build, no `kotlin("multiplatform")` → target unresolved (no detection)

token: `settings.gradle.kts`                                        → build=Gradle KTS
token: `settings.gradle` with no `.kts` sibling                     → build=Gradle Groovy
file:  `pom.xml`, no `settings.gradle*`                             → build=Maven
file:  `module.yaml` at a module root                               → build=Amper

import: `androidx.compose` or `org.jetbrains.compose`, no `res/layout/*.xml`  → ui=Compose
file:   `res/layout/*.xml`, no Compose import                                → ui=Views
        both present                                                → ui unresolved (no detection)

import: `kotlinx.coroutines` (or token `suspend fun`)               → async=kotlinx.coroutines
import: `reactor.core`, no `kotlinx.coroutines`                     → async=Reactor
import: `io.reactivex.rxjava3`, no `kotlinx.coroutines`             → async=RxJava

import: `dagger.hilt`                                               → di=Hilt
import: `org.koin`                                                  → di=Koin
import: `dagger.`, no `dagger.hilt`                                 → di=Dagger
import: `org.springframework.context`, no Dagger or Koin            → di=Spring

token:  `org.springframework.boot`                                  → framework=Spring Boot
token:  `io.ktor.plugin`                                            → framework=Ktor
token:  `io.micronaut`                                              → framework=Micronaut
token:  `io.quarkus`                                                → framework=Quarkus
import: `org.http4k`                                                → framework=http4k
import: `com.github.ajalt.clikt`                                    → framework=Clikt
import: `kotlinx.cli`                                               → framework=kotlinx-cli

import: `org.junit.jupiter`                                         → tests=JUnit5
import: `io.kotest`                                                 → tests=Kotest
import: `org.junit.Test`, no `org.junit.jupiter`                    → tests=JUnit4

path: `*Screen.kt`, `*Composable*.kt`, `ui/`, `presentation/`                     → ui, architecture
path: `*ViewModel.kt`, `*Store.kt`, `*Reducer.kt`, `*Presenter.kt`                → architecture (+ ui if a Compose state collection is present)
path: `*Controller.kt`, `*Resource.kt`, `routes/`, `api/`                         → framework, architecture
path: `*Repository.kt`, `*Dao.kt`, `data/`, `migration/`                          → async, tests
path: `*Client.kt`, `*Service.kt`, `network/`                                     → async (+ di if container-registered)
path: `build.gradle.kts`, `settings.gradle.kts`, `gradle/libs.versions.toml`      → build, baseline, target
path: `commonMain/`, `androidMain/`, `jvmMain/`, `iosMain/`                       → target, ui
path: `src/test/`, `src/androidTest/`, `*Test.kt`, `*Spec.kt`                     → tests

Coroutines win over Reactor on purpose: a Spring WebFlux project on Kotlin carries both, the
code an agent writes is in coroutines, and Reactor stays an interop detail. `architecture` and
`baseline` have no pinning row: their values are computed (`compileSdk`, `jvmTarget`), and a
computed value is never a catalog entry, so the path rows flag the axis and the config or the
user supplies the value.

## Topics

Topic → comma-separated, backtick-quoted, bare skill names that cover it (no `plugin:` prefix —
a manifest is read one platform at a time, so its own skills need no namespacing). Consumed by
spine-toolkit's methodology skills, which name a topic and resolve it here. Server-side
architectures (`arch-layered`, `arch-hexagonal`) ride under `state management` deliberately:
that row is the only channel through which core asks how a project is structured inside, and
for a server the answer is its layering.

state management → `architecture-choice`, `arch-mvvm`, `arch-mvi`, `arch-clean`, `arch-layered`, `arch-hexagonal`, `compose-state`
navigation       → `nav-compose`, `nav-multiplatform`
networking       → `net-architecture`, `net-http-clients`, `net-openapi`
persistence      → `persistence-architecture`, `persistence-room-sqldelight`
dependency graph → —
concurrency      → —
errors           → —
packaging        → —
deep links       → `nav-deeplinks`
release ops      → —

## Entrypoints

Skills spine-toolkit invokes by name, or `—` for one this platform does not provide. `setup` is the
platform half of installation: core writes the config, this skill fills `## Stack` and `## Modules`.

setup = `kotlin-setup`
