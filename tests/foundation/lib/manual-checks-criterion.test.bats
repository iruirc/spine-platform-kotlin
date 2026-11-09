#!/usr/bin/env bats
# A deferred check becomes a case in ManualChecks.md only when it needs a person. The criterion
# is core's (spine-toolkit:manual-checks); every validator has to apply it, not restate it.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
}

@test "every validator applies the criterion before it writes a case" {
  for a in jvm ui server; do
    A="$ROOT/agents/kotlin-$a-validator.md"
    grep -qF '## Does this check need a person?' "$A" || { echo "kotlin-$a-validator: no pointer to the criterion"; return 1; }
    grep -qF 'no case that needs a person, no file' "$A" || { echo "kotlin-$a-validator: auto still writes a file for any deferred check"; return 1; }
    ! grep -qF 'Nothing deferred, no file' "$A" || { echo "kotlin-$a-validator: the old auto rule is still there"; return 1; }
  done
}

@test "the platform requires the core release that carries the criterion" {
  grep -qF '{ "name": "spine-toolkit", "version": ">=2.32.0 <3" }' "$ROOT/.claude-plugin/plugin.json" \
    || { echo "the spine-toolkit floor is not >=2.32.0 <3"; return 1; }
}
