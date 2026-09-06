#!/usr/bin/env bats
# A command is one bilingual description line and a body that names the agent it
# activates in the namespaced form.

setup() { ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"; }

@test "/kotlin-init activates the namespaced init agent" {
  f="$ROOT/commands/kotlin-init.md"
  [ -f "$f" ]
  grep -qE '^description: ".* / .*"$' "$f"
  grep -q 'subagent_type=kotlin-platform:kotlin-init' "$f"
  [ -f "$ROOT/agents/kotlin-init.md" ]
}
