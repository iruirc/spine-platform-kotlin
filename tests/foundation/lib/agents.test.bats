#!/usr/bin/env bats
# One test per agent: the file has the shape Skeleton A prescribes. Content is
# reviewed by a human; shape is what a grep can hold.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  . "$ROOT/tests/foundation/helpers/shape.bash"
}

@test "kotlin-architect: shape" { assert_agent_shape "$ROOT/agents/kotlin-architect.md" kotlin-architect; }
@test "kotlin-kmp-developer: shape" { assert_agent_shape "$ROOT/agents/kotlin-kmp-developer.md" kotlin-kmp-developer; }
@test "kotlin-compose-developer: shape" { assert_agent_shape "$ROOT/agents/kotlin-compose-developer.md" kotlin-compose-developer; }
@test "kotlin-server-developer: shape" { assert_agent_shape "$ROOT/agents/kotlin-server-developer.md" kotlin-server-developer; }
@test "kotlin-jvm-tester: shape" { assert_agent_shape "$ROOT/agents/kotlin-jvm-tester.md" kotlin-jvm-tester; }
@test "kotlin-ui-tester: shape" { assert_agent_shape "$ROOT/agents/kotlin-ui-tester.md" kotlin-ui-tester; }
@test "kotlin-server-tester: shape" { assert_agent_shape "$ROOT/agents/kotlin-server-tester.md" kotlin-server-tester; }
@test "kotlin-kmp-tester: shape" { assert_agent_shape "$ROOT/agents/kotlin-kmp-tester.md" kotlin-kmp-tester; }
@test "kotlin-jvm-validator: shape" { assert_agent_shape "$ROOT/agents/kotlin-jvm-validator.md" kotlin-jvm-validator; }
@test "kotlin-ui-validator: shape" { assert_agent_shape "$ROOT/agents/kotlin-ui-validator.md" kotlin-ui-validator; }
@test "kotlin-server-validator: shape" { assert_agent_shape "$ROOT/agents/kotlin-server-validator.md" kotlin-server-validator; }
@test "kotlin-reviewer: shape" { assert_agent_shape "$ROOT/agents/kotlin-reviewer.md" kotlin-reviewer; }
