#!/usr/bin/env bats
# One test per knowledge skill: the directory has the shape Skeleton B prescribes.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  . "$ROOT/tests/foundation/helpers/shape.bash"
}
