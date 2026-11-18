# AGENTS.md — spine-platform-kotlin

> This repo is a dual-runtime Claude Code and Codex plugin: `spine-platform-kotlin`, the Kotlin
> knowledge and agents that `spine-toolkit` dispatches to. The user installs `spine-toolkit` beside
> it: Claude Code through the dependency in `.claude-plugin/plugin.json`, Codex by hand, since the
> Codex manifest declares none.
> User-project templates live in `spine-toolkit` (NOT here).
> This file configures the agent working on the plugin itself: Claude Code reads it through
> `CLAUDE.md`, Codex reads it directly.

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

- `skills/manifest/SKILL.md` — **the contract core reads.** Five required tables: `## Roles`,
  `## Axes`, `## Heuristics`, `## Topics`, `## Entrypoints`; and the optional `## Driver`.
  Everything core knows about Kotlin arrives here.
- `skills/` — knowledge skills: `architecture-choice`, `arch-*`, `compose-state`, `nav-*`, `net-*`,
  `persistence-*`, `di-*`, `concurrency-coroutines`, `reactive-flow`, `error-architecture`, `pkg-*`,
  `release-ops*`, `test-frameworks`, plus `kotlin-setup`
- `agents/` — sixteen `kotlin-*` Claude Code subagents, named by the manifest's `## Roles` table;
  `developer`, `tester` and `validator` fan out on `target`
- `commands/` — `/kotlin-init`
- `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json` — host manifests with one identity
  and one version, which `spine-ops: scripts/release.sh` moves in both
- `CLAUDE.md` — imports `AGENTS.md` for Claude Code
- `tests/foundation/` — bats suites; `tests/foundation/helpers/shape.bash` holds the structural checks
- `tests/snippets/` — the Gradle sandbox marked Kotlin blocks compile in: six modules, a default-imports
  list per marker, and `gradle/libs.versions.toml`, the one source of the versions skills name
- `scripts/` plus `conventions/i18n.md` — six **adapted forks** of core's files, each recording the
  core path it came from and that file's sha256. They are not copies — do not "restore" them to
  match core. CI goes red when core's original moves, and a human decides whether the change
  belongs here.

## Conventions

The manifest contract lives in the `spine-toolkit` plugin, as `platform-contract.md` among its
conventions. Read it from a checkout of that plugin before changing `skills/manifest/SKILL.md` —
this repo deliberately keeps no second copy, because a copy of a contract drifts from it.

## When working on this repo

- What to run and when, and how to wait for it: `spine-ops/WORKSPACE.md`.
- After changing a skill, validate it: `python3 ${CODEX_HOME:-~/.codex}/skills/.system/skill-creator/scripts/quick_validate.py skills/<name>`.
- Adding a user-facing string: add the key to BOTH `locales/en.md` AND `locales/ru.md`, then
  reference it from the skill body. Parity check must be empty.
- Adding an agent: bilingual triggers in the `description:` field, a `## Roles` row in
  `skills/manifest/SKILL.md`, and a `@test` in `tests/foundation/lib/agents.test.bats`.
- Adding a knowledge skill: a `## Topics` row and a `@test` in `tests/foundation/lib/skills.test.bats`.
- Changing `skills/manifest/SKILL.md`: run `scripts/lint-manifest.sh .` before pushing.
- Core skills are written `spine-toolkit:<skill>` everywhere; `scripts/lint-core-refs.sh` checks it.
- A Kotlin block that must compile carries `<!-- compile: <module> -->` above its fence (`-test` for the
  module's tests; `catalog` above a TOML block), and `scripts/compile-snippets.sh` builds it — with an
  OpenJDK, never GraalVM. A skill teaches the catalog's major; the previous one only under "Migrating from X".
- This repository is public, and `spine-ops: leak-guard` checks every commit, commit message, tag
  and push for absolute local paths and the owner's real project names. Never pass `--no-verify`
  and never change `core.hooksPath`. When the check stops you, replace the data with a neutral
  placeholder (`/Users/foo`, `com.example.app`, `MyApp`) instead of working around it.

## Codex compatibility

- Keep `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json` aligned on `name`, `version`,
  `author.name`, and `repository`. Never move `version` by hand: a release goes through
  `spine-ops: scripts/release.sh`, which moves it in both. Never commit the `+codex.<cachebuster>`
  suffix Codex's local reinstall flow writes into `version`.
- `skills/`, their references, `scripts/`, and `conventions/` are shared by Claude Code and Codex.
  Shared instructions must not rely solely on a host-specific environment variable or component.
- `agents/` are Claude Code subagents; in Codex the orchestrator hands an agent's file to
  `spawn_agent` as its role instructions (`runtimes/codex-cli.md` of spine-toolkit), so keep them
  free of anything only Claude Code has. `commands/` are Claude Code only.
- The Codex manifest intentionally omits the Claude dependency declaration: the user installs
  `spine-toolkit` beside this plugin. A skill that only `spine-toolkit` or an agent drives —
  `manifest`, `kotlin-setup`, `gradle-toolchain` — carries `policy.allow_implicit_invocation: false`
  in its `skills/<name>/agents/openai.yaml` and no `default_prompt`. This prevents automatic selection but does not disable explicit `$skill` use.
