#!/usr/bin/env bats
# The vendored copy of core's lint, run against this repository's own tree at the
# floor plugin.json declares. `--ref` makes the run exact rather than degrading to
# whatever the checkout happens to sit on.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  LINT="$ROOT/scripts/lint-core-refs.sh"
  CORE="${SPINE_TOOLKIT_CORE:-$ROOT/../spine-toolkit}"
}

@test "this platform's core references resolve at the declared floor" {
  [ -d "$CORE/skills" ] || skip "no spine-toolkit checkout beside this one"
  run "$LINT" "$ROOT" --core "$CORE" --ref 1.5.0
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
