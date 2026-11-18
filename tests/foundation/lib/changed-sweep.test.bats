#!/usr/bin/env bats
# A test that walks a source tree is a sweep: it carries the '# changed: sweep' mark that
# `scripts/test-foundation.sh changed` reads, so a change under skills/ agents/ conventions/ commands/
# runs it.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
}

@test "a test that walks a source tree is marked as a sweep" {
  re='(skills|agents|conventions|templates|commands)/\*|find [^|]*(skills|agents|conventions|templates|commands)|for [a-z_]+ in [^;]*(skills|agents|conventions|templates|commands)/'
  missing=""
  for f in "$ROOT"/tests/foundation/lib/*.bats; do
    [ "$(basename "$f")" = changed-sweep.test.bats ] && continue
    grep -qE "$re" "$f" || continue
    head -10 "$f" | grep -qx '# changed: sweep' || missing="$missing $(basename "$f")"
  done
  [ -z "$missing" ] || { echo "walks a tree but carries no '# changed: sweep':$missing"; return 1; }
}
