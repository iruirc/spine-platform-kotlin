#!/usr/bin/env bats
# kotlin-platform's manifest is the five-table contract spine-toolkit documents;
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

@test "the Roles table is exactly the spec's twenty-four rows" {
  rows="$(sed -n '/^## Roles/,/^## Axes/p' "$M" \
           | grep -E '^[a-z][a-z-]*(\[[^]]+\])?[[:space:]]*=' | tr -s ' ' | sort)"
  expected="$(sort <<'EOF'
architect = kotlin-platform:kotlin-architect
reviewer = kotlin-platform:kotlin-reviewer
refactorer = kotlin-platform:kotlin-refactorer
security = kotlin-platform:kotlin-security
diagnostics = kotlin-platform:kotlin-diagnostics
init = kotlin-platform:kotlin-init
developer[target=Android] = kotlin-platform:kotlin-compose-developer
developer[target=Desktop] = kotlin-platform:kotlin-compose-developer
developer[target=Server] = kotlin-platform:kotlin-server-developer
developer[target=CLI] = kotlin-platform:kotlin-server-developer
developer[target=KMP] = kotlin-platform:kotlin-kmp-developer
developer = kotlin-platform:kotlin-kmp-developer
tester[target=Android] = kotlin-platform:kotlin-ui-tester
tester[target=Desktop] = kotlin-platform:kotlin-ui-tester
tester[target=Server] = kotlin-platform:kotlin-server-tester
tester[target=CLI] = kotlin-platform:kotlin-server-tester
tester[target=KMP] = kotlin-platform:kotlin-kmp-tester
tester = kotlin-platform:kotlin-jvm-tester
validator[target=Android] = kotlin-platform:kotlin-ui-validator
validator[target=Desktop] = kotlin-platform:kotlin-ui-validator
validator[target=Server] = kotlin-platform:kotlin-server-validator
validator[target=CLI] = kotlin-platform:kotlin-server-validator
validator[target=KMP] = kotlin-platform:kotlin-ui-validator
validator = kotlin-platform:kotlin-jvm-validator
EOF
)"
  [ "$rows" = "$expected" ] || { diff <(printf '%s\n' "$expected") <(printf '%s\n' "$rows"); return 1; }
}

@test "sixteen agent files, and every one of them is named by a Roles row" {
  n="$(ls "$ROOT"/agents/*.md | wc -l | tr -d ' ')"
  [ "$n" -eq 16 ] || { echo "expected 16 agents, found $n"; return 1; }
  for f in "$ROOT"/agents/*.md; do
    a="$(basename "$f" .md)"
    grep -qE "kotlin-platform:${a}([[:space:]]|$)" "$M" || { echo "agent no Roles row names: $a"; return 1; }
  done
}

@test "the Topics table is exactly the spec's ten rows" {
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
EOF
)"
  [ "$rows" = "$expected" ] || { diff <(printf '%s\n' "$expected") <(printf '%s\n' "$rows"); return 1; }
}
