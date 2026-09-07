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
