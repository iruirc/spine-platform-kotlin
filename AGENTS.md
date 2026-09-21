# AGENTS.md — spine-platform-kotlin

Read `.claude/CLAUDE.md` first; it is the shared development guide for this repository.

## Codex compatibility

- Keep `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json` aligned on `name`, `version`,
  `author.name`, and `repository`. Never move `version` by hand: a release goes through
  `spine-ops: scripts/release.sh`, which moves it in both. Never commit the `+codex.<cachebuster>`
  suffix Codex's local reinstall flow writes into `version`.
- `skills/`, their references, `scripts/`, and `conventions/` are shared by Claude Code and Codex.
  Shared instructions must not rely solely on a host-specific environment variable or component.
- `agents/` and `commands/` are Claude Code components. Do not claim they are available in Codex
  unless they are explicitly ported to Codex skills or workflows.
- The Codex manifest intentionally omits the Claude dependency declaration, and `spine-toolkit` has
  no Codex manifest yet. Its internal `manifest` and `kotlin-setup` skills carry
  `policy.allow_implicit_invocation: false` and no `default_prompt`. This prevents automatic
  selection but does not disable explicit `$skill` use.
- After changing plugin metadata or shared skills, run the full foundation suite and the validators
  Codex bundles with its system skills: `plugin-creator/scripts/validate_plugin.py .` for the
  plugin, and `skill-creator/scripts/quick_validate.py skills/<name>` for each changed skill.
