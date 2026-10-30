# AGENTS.md — spine-platform-kotlin

Read `.claude/CLAUDE.md` first; it is the shared development guide for this repository.

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
- After changing plugin metadata or shared skills, run the full foundation suite and the validators
  Codex bundles with its system skills. Resolve each path from the loaded system skill location:
  `<plugin-creator-root>/scripts/validate_plugin.py .` for the plugin, and
  `<skill-creator-root>/scripts/quick_validate.py skills/<name>` for each changed skill.
