#!/usr/bin/env bats
# The project config is SPINE.md; CLAUDE-spine-toolkit.md is the name a project may still carry
# until core's setup renames it. Agents and skills say "the project config" and name the old
# file only in the one clause that tells a reader where to look in a project not yet migrated.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
}

@test "the legacy config name survives only where a reader must still find the file" {
  local rc=0
  hits="$(git -C "$ROOT" grep --untracked --full-name -l 'CLAUDE-spine-toolkit')" || rc=$?
  [ "$rc" -le 1 ] || { echo "git grep exited $rc — the scan did not run"; return 1; }
  offenders="$(grep -vE '^(agents/|skills/kotlin-setup/|conventions/i18n\.md|README\.md|tests/)' <<<"$hits" || true)"
  [ -z "$offenders" ] || { echo "legacy config name outside the whitelist:"; echo "$offenders"; return 1; }
}

@test "an agent names the legacy file only on the line that reads the project config first" {
  for f in "$ROOT"/agents/*.md; do
    stray="$(grep -n 'CLAUDE-spine-toolkit' "$f" | grep -v '^[0-9]*:\*\*First\*\*: Read the project config' || true)"
    [ -z "$stray" ] || { echo "$f: $stray"; return 1; }
  done
}

@test "every agent reads the project config first, under its new name" {
  for f in "$ROOT"/agents/*.md; do
    grep -q '^\*\*First\*\*: Read the project config' "$f" || { echo "$f: does not read the project config first"; return 1; }
    ! grep -q '^\*\*First\*\*: Read `\?CLAUDE-spine-toolkit' "$f" || { echo "$f: still opens on the legacy name"; return 1; }
  done
}
