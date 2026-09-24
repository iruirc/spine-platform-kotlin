---
name: kotlin-setup
description: |
  Platform half of project setup for Kotlin projects. Asks the stack questions of spine-platform-kotlin's manifest axes — target first, then only the axes that target needs — and writes the ## Stack and ## Modules blocks of an existing CLAUDE-spine-toolkit.md. Invoked by spine-toolkit:setup, which owns the config file and every other block; not invoked by the user directly.
  Use when (en): spine-toolkit:setup hands the platform its own config blocks
  Use when (ru): spine-toolkit:setup передаёт платформе её блоки конфига
---

# Kotlin Setup

The platform half of `/setup`. `spine-toolkit:setup` owns the config file — it creates
`CLAUDE-spine-toolkit.md`, writes `[LANG]`, `[WORKFLOW_MODE]`, `[PROGRESS]`, `## Platform` and the
`CLAUDE.md` import line, then hands this skill the two blocks that are the platform's:
**`## Stack` and `## Modules`**. This skill touches nothing else in the file and creates no file
of its own.

It is reached through the `setup` row of spine-platform-kotlin's manifest `## Entrypoints`. That row is
the whole binding; core never hardcodes this skill's name.

The skill does NOT create a Gradle build, does NOT modify Kotlin code, and does NOT start any
workflow. To generate a project from scratch, use the `@spine-platform-kotlin:kotlin-init` agent (via the
`/kotlin-init` slash command).

## Language Resolution

Special case for a delegate: `<lang>` arrives in the input from `spine-toolkit:setup`, which
resolved it before the config existed. Use it and skip steps 1-4. Otherwise, before producing any
user-facing string:

1. Read `CLAUDE-spine-toolkit.md` from the project root.
2. Find the `[LANG]` field.
3. Take the field's value, lowercase and trim it. That is `<lang>`.
4. If `<lang>` is `en` or `ru`, use it. Otherwise default to `en`.
5. Read this skill's `locales/<lang>.md`. Look up keys by H2 header.
6. If a key is missing, fall back to the same key in `locales/en.md`. If still missing, that's a bug — fail loudly with the key name.

Caching: resolve `<lang>` once per skill invocation.

## Agent Tooling

`AUQ` means the structured question mechanism. If the active host cannot provide a structured
question tool, ask numbered options in a regular message and parse the reply. Locale keys with the
`auq_` prefix remain the canonical prompt/option keys.

## Input

```
lang        = en | ru                       # resolved by spine-toolkit:setup
state       = A | B | C | D | E             # its State Detection branch, informational
config_path = path to CLAUDE-spine-toolkit.md   # already written, core blocks filled
stack       = {axis: value, …}              # answers core's caller already collected; usually empty
```

`stack` is what `/kotlin-init` gives back: the scaffolding agent has just asked the user for the
target, UI, DI and the rest, and an axis whose answer arrives here as an `## Axes` value is not
asked about again. Core forwards it without reading it, so the values are checked here — against
`## Axes`, like any other answer, and only for an axis the config has not already answered.

Nothing below branches on `state`: what matters is whether the config's `## Stack` already carries
axis lines, and the file answers that directly.

## Algorithm

```
1. Detect a Kotlin project:
   Any of settings.gradle.kts / settings.gradle / build.gradle.kts / build.gradle / pom.xml /
   module.yaml in the root.
   ↓ if none → render `error_not_kotlin_project`. Return without writing. Core reports the
     project as configured with ## Stack left unset — spine-toolkit still works, one AUQ per
     axis per task, and nothing this skill would have written was knowable anyway.

2. Read ## Stack from config_path.
   ↓ it holds only the template's placeholder → no axis has a value yet; every axis is
     unresolved.
   ↓ it holds `- <label>: <value>` lines → a line is that axis's value UNLESS its value is still
     an angle-bracketed option list (an unanswered template line).
     A label that matches the text of an `auq_axis_<axis>_label` key in any of this skill's locales
     is that axis's line written with its question label: rewrite the label to the axis's line
     label, keep the value, and report `report_axis_renamed`. A label matching no line label and no question label is kept
     verbatim and reported as `report_axis_unknown` — losing a value the user wrote is worse than
     carrying an unread line.

   Then fill the still-unresolved axes — and only those — from the input's `stack`. The config
   wins wherever it holds an answered line. Take an input value only if this manifest's ## Axes
   lists it for that axis; one it does not list is ignored and its axis stays unresolved, because
   the caller spelled it in its own vocabulary and one re-asked question is cheaper than a ##
   Stack line spine-toolkit:stack-detect will never match.

3. Ask `target` first if it is still unresolved (label `auq_axis_target_label`, options from
   ## Axes). Then ask, for every axis still without a value, ONLY the axes the resolved target
   needs (see Axes by Target). Labels come from locale keys `auq_axis_<axis>_label`; options
   come from the manifest's ## Axes for that axis — the manifest is the source of truth, this
   skill only labels the questions.
   - `architecture`: if the user says "I don't know" / "advise me" → run `architecture-choice`,
     bring its result back as the answer plus a one-line justification.

4. Write ## Stack: one `- <Line label>: <value>` line per axis that has a value — the label from
   Stack Line Labels, never a question label — in the manifest's
   ## Axes order, replacing the template's placeholder line — then, beneath them and verbatim,
   the lines step 2 preserved because their label matches no current axis. An axis the target
   does not need gets no line: a `- UI:` line on a server project is a claim nothing verified.
   `ecosystem` gets no line — it is a property of the platform, not of the project.

5. Write ## Modules from the build's module list:
   - Gradle: every `include("...")` / `include(":a", ":b")` / `include ':a'` in
     settings.gradle(.kts); Maven: every `<module>` in the root pom.xml; Amper: every
     module.yaml below the root.
   - For each module, resolve `target` (and `framework`, `ui` where a signal exists) with the
     manifest's ## Heuristics applied to that module's own build script.
   - A module whose resolved values differ from the root's ## Stack gets a line
     `- <module>: <path> — target: <value>[, framework: <value>][, ui: <value>]`.
   - No differing module → leave the template's placeholder. Otherwise render
     `report_modules_written` with {n} = number of lines written.
   This is how a monorepo whose root `target` the heuristics left unresolved (a client and a
   server in one build) gets its answer without asking twice.

6. Return {stack_lines, notes} to spine-toolkit:setup, which renders the one report. `notes`
   holds the step-2 `report_axis_renamed` and `report_axis_unknown` lines and the step-5
   `report_modules_written` line,
   already rendered in <lang>, and is empty when there was nothing to report.
```

## Axes by Target

Which axes step 3 asks, per resolved `target`. `target` itself is always first.

| `target` | Asked (if still unresolved) |
|---|---|
| Android | `ui`, `di`, `architecture`, `baseline`, `tests`, `build` |
| Desktop | `ui`, `di`, `architecture`, `baseline`, `tests`, `build` |
| Server | `framework`, `async`, `di`, `architecture`, `baseline`, `tests`, `build` |
| CLI | `framework`, `baseline`, `tests`, `build` |
| KMP | `ui`, `di`, `architecture`, `baseline`, `tests`, `build` |

`async` is not asked on Android, Desktop or KMP: `kotlinx.coroutines` is the only answer a Compose
or shared module gives, and the heuristics pin it from the first `suspend fun`. A project that
really runs RxJava on Android has the line detected, never asked. `framework` means nothing to a
KMP shared module, and its `ui` question offers "no UI" beside the catalog values — that answer
writes no `- UI:` line.

On a Server, the framework decides DI.
When `framework` is `Spring Boot`, `di` is not asked and the line is `- DI: Spring`.
When it is `Micronaut` or `Quarkus`, `di` is not asked and gets no line: the container is the
framework's own, and no DI skill of this plugin covers it. A CLI gets no
`- DI:` or `- Architecture:` line: its layers are `arch-layered`'s, its graph is built in `main()`.

Axis values are proper nouns from the catalog and are **never translated**: the answer is matched
back against `## Axes`, so a localized option label resolves nothing.

## Stack Line Labels

The label of each `## Stack` line — the only spelling `spine-toolkit:stack-detect`, the agents and
the other skills read. The question labels in the locale files are for asking, never for writing.

| Axis | Line label |
|---|---|
| `target` | `Target` |
| `ui` | `UI` |
| `async` | `Async` |
| `di` | `DI` |
| `framework` | `Framework` |
| `architecture` | `Architecture` |
| `build` | `Build` |
| `baseline` | `Baseline` |
| `tests` | `Tests` |

## Edge cases

- **Not a Kotlin project** → `error_not_kotlin_project`. Return without writing.
- **AUQ unavailable** → text fallback with numbered options.
- **Config file absent** → this skill was invoked out of order. Say so and stop; `/setup` creates it.
- **Both a client and a server plugin in the root build** → `target` unresolved by heuristics; ask
  it (the user names the primary surface), then let step 5's `## Modules` carry the other.

## What this skill does NOT do

- Does NOT create or rename `CLAUDE-spine-toolkit.md`, `CLAUDE.md`, `Tasks/` or `Docs/` — that is `spine-toolkit:setup`.
- Does NOT write `[LANG]`, `[WORKFLOW_MODE]`, `[PROGRESS]`, `## Platform` or `## Agents`.
- Does NOT create a Gradle build, sources, `libs.versions.toml`, lint configs, or `README.md` — that is `@spine-platform-kotlin:kotlin-init`.
- Does NOT modify Kotlin code or build scripts.
- Does NOT start workflows or call `spine-toolkit:orchestrator`.
- Does NOT init git, make commits, or run Gradle.
