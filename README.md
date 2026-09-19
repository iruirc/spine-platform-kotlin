# spine-platform-kotlin

[![release](https://img.shields.io/github/v/tag/iruirc/spine-platform-kotlin?sort=semver&label=release&color=0969da)](https://github.com/iruirc/spine-platform-kotlin)
[![license](https://img.shields.io/github/license/iruirc/spine-platform-kotlin?color=555)](LICENSE)
[![requires spine-toolkit](https://img.shields.io/badge/requires-spine--toolkit-0969da)](https://github.com/iruirc/spine-toolkit)

The Kotlin platform plugin for **spine-toolkit**. One plugin for three surfaces — Android,
Compose Desktop and JVM servers, with KMP as the way they share code — carrying sixteen
specialized agents, twenty-nine architecture and infrastructure skills, and the manifest that
declares all of it to the orchestrator.

It is not a standalone toolkit: on its own it has skills you can invoke by hand, but nothing that
runs a task. spine-toolkit supplies the process; this plugin supplies who does the work and what
they know.

## Install

```
/plugin marketplace add iruirc/claude-marketplace
/plugin install spine-platform-kotlin
```

`spine-toolkit` is declared as a dependency and installs with it. Then, in an existing project:

```
/setup
```

That is spine-toolkit's command: it writes `CLAUDE-spine-toolkit.md`, asks which platform serves
this project when more than one is installed, and hands this plugin its two blocks — `## Stack`
and `## Modules`. The stack questions start with the **target** (Android / Desktop / Server /
CLI / KMP) and ask only the axes that target needs; a Gradle build's modules land in
`## Modules` when their stack differs from the root's, which is how a monorepo holding a KMP
client and a Ktor server is configured once.

A project from scratch is this plugin's own command: `/kotlin-init` creates one Gradle build for
the chosen target and writes the toolkit config from the answers it collected.

## What it provides

**Sixteen agents** behind the orchestrator's nine roles. Three roles fan out on the target,
because what a developer, a tester and a validator *run* differs between a Compose screen, a
Ktor route and a shared module; the other six reason the same way on every surface.

| Role | Agent(s) |
|---|---|
| architect | `kotlin-architect` |
| developer | `kotlin-compose-developer` (Android, Desktop) · `kotlin-server-developer` (Server, CLI) · `kotlin-kmp-developer` (KMP, and the fallback) |
| tester | `kotlin-ui-tester` (Android, Desktop) · `kotlin-server-tester` (Server, CLI) · `kotlin-kmp-tester` (KMP) · `kotlin-jvm-tester` (fallback) |
| reviewer | `kotlin-reviewer` |
| refactorer | `kotlin-refactorer` |
| validator | `kotlin-ui-validator` (Android, Desktop, KMP) · `kotlin-server-validator` (Server, CLI) · `kotlin-jvm-validator` (fallback) |
| security | `kotlin-security` — OWASP Mobile Top-10 and OWASP Top-10 |
| diagnostics | `kotlin-diagnostics` |
| init | `kotlin-init` |

The fallback agents cover the tooling every project shares — build and test on the JVM — so a
project whose target could not be resolved gets fewer claims, never wrong ones.

**Knowledge skills**, grouped the way the manifest's `## Topics` table groups them:

- *Architecture* — `architecture-choice` (the compass, run once), then `arch-mvvm`, `arch-mvi`,
  `arch-clean` for a UI; `arch-layered`, `arch-hexagonal` for a server; `compose-state` for where
  state lives in Compose.
- *Navigation* — `nav-compose`, `nav-multiplatform`, `nav-deeplinks`.
- *Networking* — `net-architecture`, `net-http-clients`, `net-openapi`.
- *Persistence* — `persistence-architecture`, `persistence-room-sqldelight` (client),
  `persistence-jvm-orm` (server), `persistence-migrations` (both).
- *DI* — `di-composition-root` (where the graph is assembled), `di-hilt`, `di-koin`, `di-spring`.
- *Concurrency* — `concurrency-coroutines`, `reactive-flow`.
- *Cross-cutting* — `error-architecture`.
- *Packaging* — `pkg-gradle-modules`, `pkg-kmp-source-sets`.
- *Release* — `release-ops` (shared and desktop), `release-ops-android`, `release-ops-server`.

These are decision skills: which pattern at these inputs, where the boundary goes, what to inject
with. For API-level reference — Compose modifiers, AGP migrations, Retrofit recipes — install a
catalog beside this plugin: JetBrains' `Kotlin/kotlin-agent-skills` and the community
`rcosteira79/android-skills` are the two this plugin was designed next to, and neither overlaps
the ten topics here.

## The manifest

`skills/manifest/SKILL.md` is the contract surface. Six tables, read by invoking the skill:

| Table | Declares |
|---|---|
| `## Roles` | role → `spine-platform-kotlin:<agent>`, nine roles, three fanned out on `target`, none absent |
| `## Axes` | `ecosystem = kotlin` plus `target`, `ui`, `async`, `di`, `framework`, `architecture`, `build`, `baseline`, `tests` and their allowed values |
| `## Heuristics` | which repo signals (build plugins, imports, paths) pin which axis value — written so nested signals (a KMP build with an Android target) match exactly one row |
| `## Topics` | topic → the skills that cover it, for the orchestrator's methodology skills |
| `## Entrypoints` | `setup = kotlin-setup` — the platform half of installation |
| `## Driver` | the driver a project gets when it never chose one, and the surfaces its projects run on |

The manifest is the only thing spine-toolkit reads here. Everything else in this plugin is reached
through it, or invoked by name by an agent.

## Requirements

- `spine-toolkit` `>=2.0.0 <3`, declared as a dependency in `plugin.json`. An installed core
  outside that range is not a warning: the host demotes this plugin and it does not load at all.
- The validators drive Android through `adb` and the `mobile` MCP, desktop apps through the same
  MCP, and servers with `curl`; a project with none of those available sets `[DRIVE_APP] = [off]`
  in its config and the checks become a hand-run script.
- Foundation tests need `bats-core` ≥ 1.10 (`brew install bats-core`).

## Internationalization

English is the source of truth. User-facing strings live in `skills/<name>/locales/en.md` with a
key-for-key `ru.md` beside it — in 1.0 that is `kotlin-setup` alone. The active language comes
from the project config's `[LANG]` field. Whatever it is, the agents and `kotlin-setup` list
their triggers in both languages; the knowledge skills list English ones.
Convention: `conventions/i18n.md`.

## Development

```
scripts/test-foundation.sh all
scripts/lint-i18n.sh
scripts/lint-locales.sh
scripts/lint-manifest.sh .
scripts/lint-core-refs.sh . --core "$SPINE_TOOLKIT_CORE"
```

`SPINE_TOOLKIT_CORE` is a checkout of core; the suite falls back to one sitting beside this
repository, and skips the check when there is none.

The five scripts under `scripts/` and `conventions/i18n.md` are **adapted forks** of spine-toolkit's,
not copies: each records the core file it came from and that file's sha256, and CI goes red when the
original moves, so a human decides whether the change belongs here.
