#!/usr/bin/env bats
# One test per agent: the file has the shape Skeleton A prescribes. Content is
# reviewed by a human; shape is what a grep can hold.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  . "$ROOT/tests/foundation/helpers/shape.bash"
}

@test "kotlin-architect: shape" { assert_agent_shape "$ROOT/agents/kotlin-architect.md" kotlin-architect; }
@test "kotlin-kmp-developer: shape" { assert_agent_shape "$ROOT/agents/kotlin-kmp-developer.md" kotlin-kmp-developer; }
