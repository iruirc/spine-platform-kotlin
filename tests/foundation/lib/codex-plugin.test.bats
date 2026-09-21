#!/usr/bin/env bats
# Codex and Claude Code share the same skills and release identity. These tests keep the two host
# manifests aligned and preserve the invocation boundary of toolkit-driven internal skills.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  CLAUDE_MANIFEST="$ROOT/.claude-plugin/plugin.json"
  CODEX_MANIFEST="$ROOT/.codex-plugin/plugin.json"
}

@test "the Codex plugin manifest has the required native shape" {
  run python3 - "$CODEX_MANIFEST" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1]))
required = ["name", "version", "description", "author", "skills", "interface"]
missing = [key for key in required if key not in manifest]
assert not missing, f"missing fields: {', '.join(missing)}"
assert manifest["skills"] == "./skills/"
assert manifest["author"].get("name")
interface = manifest["interface"]
for key in ("displayName", "shortDescription", "longDescription", "developerName", "category", "capabilities"):
    assert interface.get(key), f"missing interface.{key}"
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the Claude and Codex manifests publish the same identity and version" {
  run python3 - "$CLAUDE_MANIFEST" "$CODEX_MANIFEST" <<'PY'
import json
import sys

claude = json.load(open(sys.argv[1]))
codex = json.load(open(sys.argv[2]))
for path in (("name",), ("version",), ("repository",), ("author", "name")):
    left, right = claude, codex
    for key in path:
        left, right = left[key], right[key]
    assert left == right, f"{'.'.join(path)} differs: {left!r} != {right!r}"
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "shared skills do not depend on Claude-only plugin-root environment" {
  run grep -R -n -F 'CLAUDE_PLUGIN_ROOT' "$ROOT/skills"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test "Codex UI metadata exists for every skill" {
  missing=""
  count=0
  for skill in "$ROOT"/skills/*; do
    [ -d "$skill" ] || continue
    count=$((count + 1))
    [ -f "$skill/agents/openai.yaml" ] || missing="$missing $(basename "$skill")"
  done
  [ "$count" -ge 25 ] || { echo "scan went vacuous: $count skills"; return 1; }
  [ -z "$missing" ] || { echo "skills missing agents/openai.yaml:$missing"; return 1; }
}

@test "toolkit-driven internal skills require explicit Codex invocation" {
  for skill in manifest kotlin-setup; do
    metadata="$ROOT/skills/$skill/agents/openai.yaml"
    grep -qx '  allow_implicit_invocation: false' "$metadata" \
      || { echo "$skill: no policy.allow_implicit_invocation: false"; return 1; }
    ! grep -q '^[[:space:]]*default_prompt:' "$metadata" \
      || { echo "$skill: unsupported Codex workflow still advertises a default_prompt"; return 1; }
  done
}

@test "standalone skills advertise an explicit starter prompt" {
  missing=""
  for skill in "$ROOT"/skills/*; do
    name="$(basename "$skill")"
    case "$name" in manifest|kotlin-setup) continue ;; esac
    metadata="$skill/agents/openai.yaml"
    grep -Fq "\$$name" "$metadata" || missing="$missing $name"
  done
  [ -z "$missing" ] || { echo "skills whose default_prompt does not name the skill:$missing"; return 1; }
}
