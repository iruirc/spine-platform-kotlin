# CLAUDE.md — spine-platform-kotlin

> This repo is a dual-runtime Claude Code and Codex plugin: `spine-platform-kotlin`, the Kotlin
> knowledge and Claude agents that `spine-toolkit` dispatches to. Claude Code declares
> `spine-toolkit` as a dependency; Codex loads the shared skills only, since `spine-toolkit` ships
> no Codex manifest. This file configures Claude when it works on the plugin itself.

## Language

en

## Persona

- This repo's source-of-truth language is English.
- User-facing strings are localized via `skills/<name>/locales/<lang>.md`. Editing localized strings
  requires updating every locale file with parity.
- When changing a skill body, never inline a localized string — always reference a locale key.
- **No process knowledge lives here.** Not stages, not `Tasks/`, not profiles, not artifacts between
  stages. That is core's, and `tests/foundation/lib/self-containment.test.bats` holds the line.
- **Three surfaces, one plugin.** Android, Compose Desktop, JVM servers and KMP are served by one
  manifest; what differs between them lives in the `target` axis and in the agents fanned out on it,
  never in a second plugin.

## Repository layout

- `skills/manifest/SKILL.md` — **the contract core reads.** Five tables: `## Roles`, `## Axes`,
  `## Heuristics`, `## Topics`, `## Entrypoints`. Everything core knows about Kotlin arrives here.
- `skills/` — knowledge skills: `architecture-choice`, `arch-*`, `compose-state`, `nav-*`, `net-*`,
  `persistence-*`, `di-*`, `concurrency-coroutines`, `reactive-flow`, `error-architecture`, `pkg-*`,
  `release-ops*`, plus `kotlin-setup`
- `agents/` — sixteen `kotlin-*` Claude Code subagents, named by the manifest's `## Roles` table;
  `developer`, `tester` and `validator` fan out on `target`
- `commands/` — `/kotlin-init`
- `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json` — host manifests with one identity
  and one version, which `spine-ops: scripts/release.sh` moves in both
- `AGENTS.md` — Codex repository guidance that points back to this shared development guide
- `tests/foundation/` — bats suites; `tests/foundation/helpers/shape.bash` holds the structural checks
- `scripts/` plus `conventions/i18n.md` — six **adapted forks** of core's files, each recording the
  core path it came from and that file's sha256. They are not copies — do not "restore" them to
  match core. CI goes red when core's original moves, and a human decides whether the change
  belongs here.

## Conventions

The manifest contract lives in the `spine-toolkit` plugin, as `platform-contract.md` among its
conventions. Read it from a checkout of that plugin before changing `skills/manifest/SKILL.md` —
this repo deliberately keeps no second copy, because a copy of a contract drifts from it.

## When working on this repo

- Adding a user-facing string: add the key to BOTH `locales/en.md` AND `locales/ru.md`, then
  reference it from the skill body. Parity check must be empty.
- Adding an agent: bilingual triggers in the `description:` field, a `## Roles` row in
  `skills/manifest/SKILL.md`, and a `@test` in `tests/foundation/lib/agents.test.bats`.
- Adding a knowledge skill: a `## Topics` row and a `@test` in `tests/foundation/lib/skills.test.bats`.
- Changing `skills/manifest/SKILL.md`: run `scripts/lint-manifest.sh .` before pushing.
- Core skills are written `spine-toolkit:<skill>` everywhere; `scripts/lint-core-refs.sh` checks it.
