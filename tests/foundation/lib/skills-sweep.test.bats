#!/usr/bin/env bats
# changed: sweep skills agents
# Split from skills.test.bats: the tests that walk skills/ and agents/.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
}

@test "thirty knowledge skills, every one named by a Topics row" {
  topics="$(sed -n '/^## Topics/,/^## /p' "$ROOT/skills/manifest/SKILL.md" | grep '→' \
              | grep -oE '`[a-z][a-z-]+`' | tr -d '`' | sort -u)"
  n="$(printf '%s\n' "$topics" | grep -c . || true)"
  [ "$n" -eq 30 ] || { echo "expected 30 topic skills, found $n"; return 1; }
  for d in "$ROOT"/skills/*/; do
    s="$(basename "$d")"
    case "$s" in manifest|kotlin-setup|gradle-toolchain) continue ;; esac
    grep -qx "$s" <<<"$topics" || { echo "knowledge skill no Topics row names: $s"; return 1; }
  done
}

@test "every knowledge skill is named by at least one agent" {
  # A skill no agent consults is a skill the orchestrator can reach only through
  # a methodology topic — which is fine — but one no agent AND no topic names is dead.
  for d in "$ROOT"/skills/*/; do
    s="$(basename "$d")"
    case "$s" in manifest|kotlin-setup|gradle-toolchain) continue ;; esac
    grep -rq "\`$s\`" "$ROOT/agents" || { echo "no agent references skill: $s"; return 1; }
  done
}
