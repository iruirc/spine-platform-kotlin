#!/usr/bin/env bats
# spine-platform-kotlin's manifest is the five-table contract spine-toolkit documents;
# these tests check the real manifest against that contract from this side, since
# core's suite must reach no tree but core's.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  M="$ROOT/skills/manifest/SKILL.md"
}

@test "manifest declares all five tables, and the optional sixth" {
  for s in Roles Axes Heuristics Topics Entrypoints; do
    grep -q "^## $s\$" "$M"
  done
  # Optional in the contract, mandatory here: this platform drives an app on two
  # of its five targets, and without the block every project resolves to no driver.
  grep -q '^## Driver$' "$M"
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
           "release ops" "testing"; do
    grep -qE "^${t}[[:space:]]*→" <<<"$rows" || missing="$missing '$t'"
  done
  [ -z "$missing" ] || { echo "topic spine-toolkit names with no row here:$missing"; return 1; }
}

@test "no topic row beyond the eleven core reads" {
  # Rows start at column one with the topic name; the prose above the table also
  # carries an arrow, so the count is anchored. The eleventh is `testing`, which
  # core added in 2.5.0 for the agents that write test code.
  n="$(sed -n '/^## Topics/,/^## Entrypoints/p' "$M" | grep -cE '^[a-z][a-z ]*→' || true)"
  [ "$n" -eq 11 ] || { echo "expected 11 topic rows, found $n"; return 1; }
}

@test "every role that names an agent names a file that exists" {
  refs="$(grep -oE 'spine-platform-kotlin:kotlin-[a-z0-9-]+' "$M" | sort -u)"
  for ref in $refs; do
    [ -f "$ROOT/agents/${ref#spine-platform-kotlin:}.md" ] || { echo "no agent file for $ref"; return 1; }
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

@test "the Roles table is exactly the spec's twenty-four rows" {
  rows="$(sed -n '/^## Roles/,/^## Axes/p' "$M" \
           | grep -E '^[a-z][a-z-]*(\[[^]]+\])?[[:space:]]*=' | tr -s ' ' | sort)"
  expected="$(sort <<'EOF'
architect = spine-platform-kotlin:kotlin-architect
reviewer = spine-platform-kotlin:kotlin-reviewer
refactorer = spine-platform-kotlin:kotlin-refactorer
security = spine-platform-kotlin:kotlin-security
diagnostics = spine-platform-kotlin:kotlin-diagnostics
init = spine-platform-kotlin:kotlin-init
developer[target=Android] = spine-platform-kotlin:kotlin-compose-developer
developer[target=Desktop] = spine-platform-kotlin:kotlin-compose-developer
developer[target=Server] = spine-platform-kotlin:kotlin-server-developer
developer[target=CLI] = spine-platform-kotlin:kotlin-server-developer
developer[target=KMP] = spine-platform-kotlin:kotlin-kmp-developer
developer = spine-platform-kotlin:kotlin-kmp-developer
tester[target=Android] = spine-platform-kotlin:kotlin-ui-tester
tester[target=Desktop] = spine-platform-kotlin:kotlin-ui-tester
tester[target=Server] = spine-platform-kotlin:kotlin-server-tester
tester[target=CLI] = spine-platform-kotlin:kotlin-server-tester
tester[target=KMP] = spine-platform-kotlin:kotlin-kmp-tester
tester = spine-platform-kotlin:kotlin-jvm-tester
validator[target=Android] = spine-platform-kotlin:kotlin-ui-validator
validator[target=Desktop] = spine-platform-kotlin:kotlin-ui-validator
validator[target=Server] = spine-platform-kotlin:kotlin-server-validator
validator[target=CLI] = spine-platform-kotlin:kotlin-server-validator
validator[target=KMP] = spine-platform-kotlin:kotlin-ui-validator
validator = spine-platform-kotlin:kotlin-jvm-validator
EOF
)"
  [ "$rows" = "$expected" ] || { diff <(printf '%s\n' "$expected") <(printf '%s\n' "$rows"); return 1; }
}

@test "sixteen agent files, and every one of them is named by a Roles row" {
  n="$(ls "$ROOT"/agents/*.md | wc -l | tr -d ' ')"
  [ "$n" -eq 16 ] || { echo "expected 16 agents, found $n"; return 1; }
  for f in "$ROOT"/agents/*.md; do
    a="$(basename "$f" .md)"
    grep -qE "spine-platform-kotlin:${a}([[:space:]]|$)" "$M" || { echo "agent no Roles row names: $a"; return 1; }
  done
}

@test "the Topics table is exactly the spec's eleven rows" {
  rows="$(sed -n '/^## Topics/,/^## Entrypoints/p' "$M" | grep -E '^[a-z][a-z ]*→' | tr -s ' ' | sort)"
  expected="$(sort <<'EOF'
state management → `architecture-choice`, `arch-mvvm`, `arch-mvi`, `arch-clean`, `arch-layered`, `arch-hexagonal`, `compose-state`
navigation → `nav-compose`, `nav-multiplatform`
networking → `net-architecture`, `net-http-clients`, `net-openapi`
persistence → `persistence-architecture`, `persistence-room-sqldelight`, `persistence-jvm-orm`, `persistence-migrations`
dependency graph → `di-composition-root`, `di-hilt`, `di-koin`, `di-spring`
concurrency → `concurrency-coroutines`, `reactive-flow`
errors → `error-architecture`
packaging → `pkg-gradle-modules`, `pkg-kmp-source-sets`
deep links → `nav-deeplinks`
release ops → `release-ops`, `release-ops-android`, `release-ops-server`
testing → `test-frameworks`
EOF
)"
  [ "$rows" = "$expected" ] || { diff <(printf '%s\n' "$expected") <(printf '%s\n' "$rows"); return 1; }
}
