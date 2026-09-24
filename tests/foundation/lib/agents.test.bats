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
@test "kotlin-refactorer: shape" { assert_agent_shape "$ROOT/agents/kotlin-refactorer.md" kotlin-refactorer; }
@test "kotlin-security: shape" { assert_agent_shape "$ROOT/agents/kotlin-security.md" kotlin-security; }
@test "kotlin-diagnostics: shape" { assert_agent_shape "$ROOT/agents/kotlin-diagnostics.md" kotlin-diagnostics; }
@test "kotlin-init: shape" { assert_agent_shape "$ROOT/agents/kotlin-init.md" kotlin-init; }

@test "kotlin-security names the three ways it is called, and writes nothing in a workflow" {
  f="$ROOT/agents/kotlin-security.md"
  s="$(awk '$0=="## Invocation Context"{f=1;next} f&&/^## /{exit} f' "$f")"
  for token in '**triage**' '**lens**' '**audit**' '**write no artifact and apply no patch**'; do
    grep -qF "$token" <<<"$s" || { echo "## Invocation Context does not say $token"; return 1; }
  done
  ! grep -qF 'Your output must be appended/written to the task-stage file' "$f" \
    || { echo "the lens is still told to write a stage file"; return 1; }
  ! grep -qF 'during the Research panel' "$f" || { echo "Related Agents still describes a Research panel"; return 1; }
}

@test "no agent recommends a DI library the di axis does not list" {
  [ "$(ls "$ROOT"/agents/*.md | wc -l)" -ge 16 ] || { echo "the scan went vacuous"; return 1; }
  ! grep -l 'Kodein' "$ROOT"/agents/*.md
}

@test "the compose developer says what a Views project gets" {
  grep -qF 'When `## Stack` says `- UI: Views`' "$ROOT/agents/kotlin-compose-developer.md"
}
