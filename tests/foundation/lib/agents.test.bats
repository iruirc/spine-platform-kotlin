#!/usr/bin/env bats
# One test per agent: the file has the shape Skeleton A prescribes. Content is
# reviewed by a human; shape is what a grep can hold.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  . "$ROOT/tests/foundation/helpers/shape.bash"
}
