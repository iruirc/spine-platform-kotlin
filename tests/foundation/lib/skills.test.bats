#!/usr/bin/env bats
# One test per knowledge skill: the directory has the shape Skeleton B prescribes.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  . "$ROOT/tests/foundation/helpers/shape.bash"
}

@test "architecture-choice: shape" { assert_skill_shape "$ROOT/skills/architecture-choice"; }
@test "arch-mvvm: shape" { assert_skill_shape "$ROOT/skills/arch-mvvm"; }
