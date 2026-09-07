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
