#!/usr/bin/env bats
# bash 3.2, macOS's /bin/bash, does not stop a bats test on a failing `[[ ]]` that is not its last
# command, so an assertion written as a bare `[[ ]]` line passes whatever it tests. Each one carries
# `|| false`, or another `||`, to fail the test. Lines inside a heredoc are text, not assertions.

bare_double_brackets() {   # <file>...
  awk '
    FNR == 1 { term = "" }
    term != "" { if ($0 ~ "^[[:space:]]*" term "[[:space:]]*$") term = ""; next }
    /^[[:space:]]*\[\[ .*\]\][[:space:]]*$/ { print FILENAME ":" FNR ": " $0 }
    match($0, /<<-?[[:space:]]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*/) {
      term = substr($0, RSTART, RLENGTH); sub(/^<<-?[[:space:]]*['"'"'"]?/, "", term)
    }
  ' "$@"
}

@test "no assertion is a bare [[ ]] line" {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  found="$(bare_double_brackets $(find "$ROOT/tests/foundation" -name '*.bats' | sort))"
  [ -z "$found" ] || { echo "$found"; return 1; }
}

@test "the check skips heredocs and sees a bare line after one" {
  t="$BATS_TEST_TMPDIR/t.bats"
  printf '%s\n' '@test "x" {' "  cat <<'S'" '  [[ a == a ]]' 'S' '  [[ b == b ]] || false' '  [[ c == c ]]' '}' >"$t"
  [ "$(bare_double_brackets "$t")" = "$t:6:   [[ c == c ]]" ]
}
