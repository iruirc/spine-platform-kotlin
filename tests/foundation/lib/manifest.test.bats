#!/usr/bin/env bats
# kotlin-platform's manifest is the five-table contract spine-toolkit documents;
# these tests check the real manifest against that contract from this side, since
# core's suite must reach no tree but core's.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  M="$ROOT/skills/manifest/SKILL.md"
}

@test "manifest declares all five tables" {
  for s in Roles Axes Heuristics Topics Entrypoints; do
    grep -q "^## $s\$" "$M"
  done
}

@test "the manifest passes spine-toolkit's conformance lint" {
  run "$ROOT/scripts/lint-manifest.sh" "$ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "every topic spine-toolkit asks for has a row here" {
  # Core matches literally: `deeplinks` for `deep links` reads fine on both sides
  # and resolves to nothing on every task.
  rows="$(sed -n '/^## Topics/,/^## Entrypoints/p' "$M")"
  missing=""
  for t in "state management" "navigation" "networking" "persistence" \
           "dependency graph" "concurrency" "errors" "packaging" "deep links" \
           "release ops"; do
    grep -qE "^${t}[[:space:]]*→" <<<"$rows" || missing="$missing '$t'"
  done
  [ -z "$missing" ] || { echo "topic spine-toolkit names with no row here:$missing"; return 1; }
}

@test "no topic row beyond the ten core reads" {
  # Rows start at column one with the topic name; the prose above the table also
  # carries an arrow, so the count is anchored.
  n="$(sed -n '/^## Topics/,/^## Entrypoints/p' "$M" | grep -cE '^[a-z][a-z ]*→' || true)"
  [ "$n" -eq 10 ] || { echo "expected 10 topic rows, found $n"; return 1; }
}

@test "every role that names an agent names a file that exists" {
  refs="$(grep -oE 'kotlin-platform:kotlin-[a-z0-9-]+' "$M" | sort -u)"
  for ref in $refs; do
    [ -f "$ROOT/agents/${ref#kotlin-platform:}.md" ] || { echo "no agent file for $ref"; return 1; }
  done
}

@test "every topic points at a skill that exists" {
  skills="$(sed -n '/^## Topics/,/^## /p' "$M" | grep '→' \
              | grep -oE '`[a-z][a-z-]+`' | tr -d '`' | sort -u)"
  for skill in $skills; do
    [ -d "$ROOT/skills/$skill" ] || { echo "topic names a skill with no directory: $skill"; return 1; }
  done
}

@test "ecosystem is declared and is kotlin" {
  grep -qE '^ecosystem[[:space:]]*=[[:space:]]*kotlin$' "$M"
}

@test "the setup entrypoint names a skill that exists" {
  grep -qE '^setup[[:space:]]*=[[:space:]]*`kotlin-setup`$' "$M"
  [ -f "$ROOT/skills/kotlin-setup/SKILL.md" ]
}
