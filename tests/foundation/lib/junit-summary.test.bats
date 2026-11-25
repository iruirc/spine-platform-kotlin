#!/usr/bin/env bats
# A green Gradle or Amper run prints no test count; junit-summary.sh prints one from the JUnit XML, so
# the run's log holds a line that says how many tests ran. An empty report must not read as a green 0.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="$ROOT/scripts/junit-summary.sh"
  FIX="$ROOT/tests/foundation/fixtures/junit-summary"
}

@test "sums one directory, a start tag split over lines and a property named tests aside" {
  run "$SCRIPT" "$FIX/gradle"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "JUnit XML: 5 tests, 1 failures, 0 errors, 1 skipped in 2 files" ] || { echo "$output"; return 1; }
}

@test "sums several directories, attribute order aside" {
  run "$SCRIPT" "$FIX/gradle" "$FIX/maven"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "JUnit XML: 9 tests, 1 failures, 1 errors, 1 skipped in 3 files" ] || { echo "$output"; return 1; }
}

@test "a testsuites root sums its suites, not its own totals twice" {
  run "$SCRIPT" "$FIX/suites"
  [ "$output" = "JUnit XML: 6 tests, 0 failures, 0 errors, 1 skipped in 1 files" ] || { echo "$output"; return 1; }
}

@test "no report is a failure, not a zero" {
  run --separate-stderr "$SCRIPT" "$FIX/empty"
  [ "$status" -eq 1 ] || { echo "status $status"; return 1; }
  [ -z "$output" ] || { echo "stdout: $output"; return 1; }
  grep -qF 'no TEST-*.xml' <<<"$stderr" || { echo "stderr: $stderr"; return 1; }
}

@test "no argument prints usage" {
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 2 ] || { echo "status $status"; return 1; }
  grep -qF 'usage' <<<"$stderr" || { echo "stderr: $stderr"; return 1; }
}

@test "a testsuite tag a test printed into its captured output is not counted" {
  run "$SCRIPT" "$FIX/cdata"
  [ "$output" = "JUnit XML: 2 tests, 0 failures, 0 errors, 0 skipped in 1 files" ] || { echo "$output"; return 1; }
}
