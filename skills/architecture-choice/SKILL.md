---
name: architecture-choice
description: "Use when picking the architecture stack for a Kotlin project at bootstrap or major refactor — Android, Compose Desktop, JVM server, CLI or KMP. Compass-style: five input axes (team size, lifetime, domain complexity, target surface, testing rigor) → one reference stack (MVVM / MVI / Clean Architecture / Layered / Hexagonal) plus DI, navigation and cross-cutting skills. Points to detailed skills, doesn't replace them."
---

# Architecture Choice — Decision Compass

A **meta-skill** for picking a stack at day one or at a major refactor. It teaches no pattern —
it points at the skill that does. Run it once per project; for everything after that, follow the
skill of the pattern it chose.

> **Related skills:**
> - `arch-mvvm` — the default presentation pattern, once the matrix lands on MVVM
> - `arch-mvi` — the reducer track, once one screen's state machine earns it
> - `arch-clean` — Domain / Data / Presentation layering, when business rules must be testable without Android
> - `arch-layered` — controller → service → repository, the JVM server and CLI default
> - `arch-hexagonal` — ports and adapters, when the core must not import the framework
> - `compose-state` — where screen state lives once the pattern is fixed: hoisting, remember, state holders
> - `nav-compose` — the route graph of an Android or Compose Desktop app
> - `nav-multiplatform` — the same decision on a KMP UI: navigation-compose, Decompose or Voyager
> - `di-composition-root` — DI is a **parallel** decision, not derived from the architecture; start here
> - `di-hilt` — the Android-only DI track
> - `di-koin` — the KMP, Compose Desktop and Ktor DI track
> - `di-spring` — DI when the container is Spring's own
> - `error-architecture` — cross-cutting: cheap on day one, expensive to retrofit
> - `concurrency-coroutines` — which dispatcher and which scope each layer of the chosen stack gets
> - `net-architecture` — the networking boundary, whichever pattern won
> - `persistence-architecture` — the Repository boundary and the source-of-truth policy
> - `persistence-room-sqldelight` — the client engine that boundary sits on
> - `persistence-jvm-orm` — the server database layer the same boundary sits on
> - `pkg-gradle-modules` — when "should we split the build at all" is being decided alongside the pattern
> - `pkg-kmp-source-sets` — the source-set layout the KMP row implies

## When to Use

- New project (`spine-platform-kotlin:kotlin-init`, or `spine-toolkit:setup` on an existing repo) and the
  active project guidance file's `## Stack` carries no `- Architecture:` line
- Major refactor with a concrete trigger: the signals in `arch-layered` that layering has run out of
  steam; the team grows past 3 devs; the domain grows explicit use cases; build time or merge
  conflicts hurt enough to consider Gradle modules
- User asks "which architecture should I pick", "what should I use for a new Android app",
  "MVVM or MVI", "Layered or Hexagonal"

If `## Stack` already names an architecture and the user is not refactoring — **don't run this
skill**. Follow the named pattern's own skill instead.

## Fast Path (skip the questionnaire)

If one of these is clearly true from context, recommend directly without running the five-axis flow:

| If user says | Recommend |
|---|---|
| "Throwaway Android prototype, 1–2 weeks" | MVVM + Manual DI; single module |
| "Greenfield Android Compose app, 1–2 devs" | MVVM + Hilt + Navigation Compose |
| "KMP client with shared business logic" | Clean Architecture (shared Domain/Data in `commonMain`) + MVVM presentation + Koin |
| "Spring Boot CRUD service" | Layered + Spring DI |
| "Ktor service with rich business rules" | Hexagonal + Koin (or Manual) |
| "CLI tool" | Layered, two layers (command → service) + Manual DI |
| "Compose Desktop utility" | MVVM + Manual DI, window-scoped state |

If none fits clearly — proceed to Five Input Axes.

## Five Input Axes

Get an answer to each before recommending a stack. Don't guess.

| Axis | Spectrum | Why it matters |
|---|---|---|
| **Team size** | solo → 2–3 → 4+ | More people → stronger boundaries to avoid stepping on each other |
| **Expected lifetime** | weeks → months → years | Longer life → invest in tests, layers, documentation conventions |
| **Domain complexity** | CRUD/forms → multiple flows → rich business rules | Rich domain → explicit use cases to keep logic out of the screen and out of the controller |
| **Target surface** | Android / Desktop / Server / CLI / KMP | Drives which pattern family applies at all: presentation patterns for a UI, layering patterns for a server, both for KMP |
| **Testing rigor** | smoke/manual → unit on logic → unit + integration + UI | Pivots toward Clean when paired with a rich domain — use cases are plain Kotlin, testable with no Android and no framework context |

**Domain complexity is independent of screen or endpoint count.** A 30-screen catalog over simple
CRUD stays MVVM; four screens over banking rules may need Clean. A 60-endpoint service that only
maps rows stays Layered; a dozen endpoints over a pricing engine may need Hexagonal.

**Don't ask about team familiarity for the default tracks (MVVM, Clean, Layered).** Do ask for the
non-default ones (MVI on Orbit or MVIKotlin, Hexagonal) — those need existing fluency, otherwise the
choice is wrong regardless of the other axes.

## Decision Matrix

Find the row that best matches reality. Thresholds are heuristics, not boundaries — at the edges,
apply the When in Doubt defaults.

| Scenario | Stack | Navigation / Entry | Why |
|---|---|---|---|
| Solo, weeks–months, simple CRUD, ≤5 screens, Android | MVVM | Navigation Compose | one ViewModel per screen; tests on ViewModel |
| Solo/pair, months–years, modest logic, Android or Desktop | MVVM + Hilt (Koin on Desktop) | Navigation Compose | testable ViewModels, DI scopes match lifecycle |
| Non-trivial state machine on a screen, unidirectional flow wanted | MVI (Orbit / MVIKotlin / hand-rolled reducer) | Navigation Compose | single State, pure reducer, exhaustive tests |
| 2–3 devs, years, rich domain, must unit-test rules without Android | Clean Architecture + MVVM presentation | Navigation Compose | use cases are plain Kotlin; Repository hides data sources |
| 4+ devs, parallel feature work | Clean + feature Gradle modules | Navigation Compose per feature graph | cross-team edges become compile errors |
| KMP: Android + iOS (+ Desktop) sharing logic | Clean (shared Domain/Data) + per-platform MVVM | `nav-multiplatform` | Domain/Data in `commonMain`, UI native or Compose Multiplatform |
| Spring Boot service, CRUD-heavy | Layered | controller → service → repository | the framework's own shape; least ceremony |
| Any server framework, rich domain, external systems to swap or fake | Hexagonal | ports in, adapters out | core has no framework import; tests through ports |
| Micronaut / Quarkus service | Layered (Hexagonal when domain is rich) | as above | compile-time DI does not change the layering choice |
| CLI | Layered, thin | command → service | commands are entry points like controllers |

**One row, not a pattern blend.** MVVM in one feature and MVI in the next, or a "Clean-Layered"
server, is usually neither pattern rather than both. The KMP row is the one **legitimate** mix — one
shared domain, one presentation pattern per platform: the same pattern across two surfaces, not
different patterns per feature.

## Stack Lines

What each recommendation writes into `## Stack` — catalog values only, because
`spine-toolkit:stack-detect` matches nothing else. The Stack column above is the advice; this
table is the record. `—` writes no line: the axis is either asked by `kotlin-setup` or, on a CLI,
not an axis of that project.

| Recommendation | `- Architecture:` | `- DI:` |
|---|---|---|
| Matrix: solo, simple CRUD, Android | `MVVM` | — |
| Matrix: modest logic, Android | `MVVM` | `Hilt` |
| Matrix: modest logic, Desktop | `MVVM` | `Koin` |
| Matrix: screen state machine | `MVI` | — |
| Matrix: rich domain, 2–3 devs | `Clean Architecture` | — |
| Matrix: 4+ devs, feature modules | `Clean Architecture` | — |
| Matrix: KMP sharing logic | `Clean Architecture` | `Koin` |
| Matrix: Spring Boot, CRUD-heavy | `Layered` | `Spring` |
| Matrix: any server, rich domain | `Hexagonal` | — |
| Matrix: Micronaut / Quarkus | `Layered` | — |
| Matrix: CLI | — | — |
| Fast Path: throwaway Android prototype | `MVVM` | `Manual` |
| Fast Path: greenfield Android Compose app | `MVVM` | `Hilt` |
| Fast Path: KMP client with shared logic | `Clean Architecture` | `Koin` |
| Fast Path: Spring Boot CRUD service | `Layered` | `Spring` |
| Fast Path: Ktor service with rich rules | `Hexagonal` | `Koin` |
| Fast Path: CLI tool | — | — |
| Fast Path: Compose Desktop utility | `MVVM` | `Manual` |

A Micronaut or Quarkus service with a rich domain takes `Hexagonal` the same way; its DI is the
framework's container and gets no line.

## Stack Cookbook

Each stack is the set of skills to follow next. Cross all of them off.

- **MVVM** → `arch-mvvm` + `compose-state` + `nav-compose`
- **MVI** → `arch-mvi` + `compose-state` + `nav-compose`
- **Clean (client)** → `arch-clean` + `arch-mvvm` + `nav-compose`; add `pkg-gradle-modules` for 4+
  devs, and `pkg-kmp-source-sets` + `nav-multiplatform` for KMP
- **Layered** → `arch-layered` + `di-spring` (Spring) or `di-koin` (Ktor) or `di-composition-root`
  "Manual"
- **Hexagonal** → `arch-hexagonal` + `arch-clean` (the domain half) + the same DI row

Cross-cutting (always, regardless of pattern):

- **DI** (parallel decision): `di-composition-root` is the entry point — it covers the manual graph
  and where the root lives on each surface; `di-hilt` on Android-only, `di-koin` on KMP, Compose
  Desktop or Ktor, `di-spring` inside a Spring context
- **Errors:** `error-architecture` from day one
- **Concurrency:** `concurrency-coroutines` — the dispatcher and scope rules per layer
- **Networking:** `net-architecture`
- **Persistence:** `persistence-architecture` for the boundary; the engine underneath it is
  `persistence-room-sqldelight` on a client, `persistence-jvm-orm` on a server
- **Modularization:** `pkg-gradle-modules` when 2+ devs or compile time hurts

## When in Doubt

| Tension | Default |
|---|---|
| MVVM vs MVI | MVVM. Add a reducer to one screen when its state machine earns it |
| Clean vs MVVM | MVVM. Extract use cases later — additive |
| Layered vs Hexagonal | Layered. Go Hexagonal when the second external system arrives or tests need the framework out |
| Hilt vs Koin | Hilt on Android-only; Koin on KMP or Desktop; never both |
| Spring Boot vs Ktor | the one the team already runs in production |
| Room vs SQLDelight | Room on Android-only; SQLDelight on KMP |
| "Should we modularize?" | Not yet. One module until 2+ devs collide or the build hurts |
| Coroutines vs Reactor on Spring | Coroutines. Reactor stays an interop detail |

## Common Mistakes

1. **Picking the most ambitious stack "just in case"** — Clean plus Hexagonal plus six Gradle
   modules for a five-screen utility costs weeks and hides intent behind indirection
2. **Mixing patterns by feature** — one feature MVVM, the next MVI, a third Clean: nobody joining
   the project can predict where logic lives. The KMP split (shared domain, per-platform
   presentation) is **not** this — one pattern per layer, not one per feature
3. **Choosing without writing it down** — record the choice in `## Stack` through Stack Lines
   so every later task reads one source of truth instead of re-deciding
4. **Refusing to migrate when the signals appear** — see the signals in `arch-layered`. A stack
   fits a project's current size, not its whole lifetime
5. **Letting a library pick the architecture** — "we use Compose, therefore MVVM" is fine; "we use
   Flow, therefore MVI" is not. A library is a tool, not a pattern

## How to Use This Skill

1. **Find and read the active project guidance file.** Prefer `CLAUDE-spine-toolkit.md` if present,
   otherwise `CLAUDE.md`, otherwise the active task documentation. If its `## Stack` already names an
   architecture and the user isn't refactoring — this skill is done; follow that pattern's skill.
   Read the other lines too: a `- Target:` line answers the target surface axis, and the
   questionnaire does not ask it again.
2. **Try Fast Path.** If a Fast Path scenario clearly applies — skip the questionnaire and recommend.
3. **Otherwise collect the Five Axes** from the user using the active agent's available question
   mechanism. If no structured question tool exists, ask concise plain-text questions. Don't infer
   the target surface from the project name or from vibes — take it from `- Target:`, or from
   the caller that invoked this skill, or ask.
4. **Pick the matching row** from the Decision Matrix. If two rows fit — apply the When in Doubt
   defaults.
5. **Write the choice into the active project guidance file's `## Stack`**: the lines Stack Lines
   gives for the chosen row, `- Architecture: <value>` and `- DI: <value>`, and nothing for a `—`
   cell. No other line, no comment.
   An existing `- DI:` line with a different value is replaced only after the user confirms — the
   DI answer may have come from `kotlin-setup` with a reason this compass does not see. When a
   caller (such as `kotlin-setup`) asked for the value, return it instead of writing — during setup
   that caller is the only writer.
6. **If the user disagrees with the recommendation** — record their choice as its catalog value,
   and state the objection (the matrix row or Fast Path line it rests on) in your answer to them.
   The config carries values, not arguments.
7. **Hand control** to `spine-platform-kotlin:kotlin-init` (new project) or
   `spine-platform-kotlin:kotlin-architect` (existing project) with the skill list from Stack Cookbook.
   A host without those agents, such as Codex, ends here with the skill list for the user to follow.

The output of this skill is one `## Stack` block in the active project guidance file and a list of
skills to follow next — nothing more. Don't generate code here.
