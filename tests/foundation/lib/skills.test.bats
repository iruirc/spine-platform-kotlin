#!/usr/bin/env bats
# One test per knowledge skill: the directory has the shape Skeleton B prescribes.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  . "$ROOT/tests/foundation/helpers/shape.bash"
}

@test "architecture-choice: shape" { assert_skill_shape "$ROOT/skills/architecture-choice"; }
@test "arch-mvvm: shape" { assert_skill_shape "$ROOT/skills/arch-mvvm"; }
@test "arch-mvi: shape" { assert_skill_shape "$ROOT/skills/arch-mvi"; }
@test "arch-clean: shape" { assert_skill_shape "$ROOT/skills/arch-clean"; }
@test "arch-layered: shape" { assert_skill_shape "$ROOT/skills/arch-layered"; }
@test "arch-hexagonal: shape" { assert_skill_shape "$ROOT/skills/arch-hexagonal"; }
@test "compose-state: shape" { assert_skill_shape "$ROOT/skills/compose-state"; }
@test "nav-compose: shape" { assert_skill_shape "$ROOT/skills/nav-compose"; }
@test "nav-multiplatform: shape" { assert_skill_shape "$ROOT/skills/nav-multiplatform"; }
@test "nav-deeplinks: shape" { assert_skill_shape "$ROOT/skills/nav-deeplinks"; }
@test "net-architecture: shape" { assert_skill_shape "$ROOT/skills/net-architecture"; }
@test "net-http-clients: shape" { assert_skill_shape "$ROOT/skills/net-http-clients"; }
@test "net-openapi: shape" { assert_skill_shape "$ROOT/skills/net-openapi"; }
@test "persistence-architecture: shape" { assert_skill_shape "$ROOT/skills/persistence-architecture"; }
@test "persistence-room-sqldelight: shape" { assert_skill_shape "$ROOT/skills/persistence-room-sqldelight"; }
@test "persistence-jvm-orm: shape" { assert_skill_shape "$ROOT/skills/persistence-jvm-orm"; }
@test "persistence-migrations: shape" { assert_skill_shape "$ROOT/skills/persistence-migrations"; }
@test "di-composition-root: shape" { assert_skill_shape "$ROOT/skills/di-composition-root"; }
@test "di-hilt: shape" { assert_skill_shape "$ROOT/skills/di-hilt"; }
@test "di-koin: shape" { assert_skill_shape "$ROOT/skills/di-koin"; }
@test "di-spring: shape" { assert_skill_shape "$ROOT/skills/di-spring"; }
@test "concurrency-coroutines: shape" { assert_skill_shape "$ROOT/skills/concurrency-coroutines"; }
@test "reactive-flow: shape" { assert_skill_shape "$ROOT/skills/reactive-flow"; }
@test "error-architecture: shape" { assert_skill_shape "$ROOT/skills/error-architecture"; }
@test "pkg-gradle-modules: shape" { assert_skill_shape "$ROOT/skills/pkg-gradle-modules"; }
@test "pkg-kmp-source-sets: shape" { assert_skill_shape "$ROOT/skills/pkg-kmp-source-sets"; }
@test "release-ops: shape" { assert_skill_shape "$ROOT/skills/release-ops"; }
@test "release-ops-android: shape" { assert_skill_shape "$ROOT/skills/release-ops-android"; }
@test "release-ops-server: shape" { assert_skill_shape "$ROOT/skills/release-ops-server"; }

@test "twenty-nine knowledge skills, every one named by a Topics row" {
  topics="$(sed -n '/^## Topics/,/^## /p' "$ROOT/skills/manifest/SKILL.md" | grep '→' \
              | grep -oE '`[a-z][a-z-]+`' | tr -d '`' | sort -u)"
  n="$(printf '%s\n' "$topics" | grep -c . || true)"
  [ "$n" -eq 29 ] || { echo "expected 29 topic skills, found $n"; return 1; }
  for d in "$ROOT"/skills/*/; do
    s="$(basename "$d")"
    case "$s" in manifest|kotlin-setup) continue ;; esac
    grep -qx "$s" <<<"$topics" || { echo "knowledge skill no Topics row names: $s"; return 1; }
  done
}

@test "every knowledge skill is named by at least one agent" {
  # A skill no agent consults is a skill the orchestrator can reach only through
  # a methodology topic — which is fine — but one no agent AND no topic names is dead.
  for d in "$ROOT"/skills/*/; do
    s="$(basename "$d")"
    case "$s" in manifest|kotlin-setup) continue ;; esac
    grep -rq "\`$s\`" "$ROOT/agents" || { echo "no agent references skill: $s"; return 1; }
  done
}
