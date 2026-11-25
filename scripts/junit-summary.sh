#!/usr/bin/env bash
# Prints one line counting the tests of a run from its JUnit XML reports:
#   JUnit XML: N tests, F failures, E errors, S skipped in K files
# A green Gradle or Amper run prints no count of its own, so a run's command calls this after the
# tests, and the line lands in the same log. Sums the tests, failures, errors and skipped attributes
# of every <testsuite> start tag (a <testsuites> root's own totals are not counted again). Reads the
# TEST-*.xml files directly in each named directory, not in its subdirectories; runs nothing.
# Usage: junit-summary.sh <reports-dir>...
# Exit: 0 printed; 1 no TEST-*.xml in any named directory; 2 usage.
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: junit-summary.sh <reports-dir>..." >&2
  exit 2
fi

files=()
for d in "$@"; do
  for f in "$d"/TEST-*.xml; do
    [ -f "$f" ] && files+=("$f")
  done
done

if [ "${#files[@]}" -eq 0 ]; then
  echo "junit-summary: no TEST-*.xml in $*" >&2
  exit 1
fi

awk -v k="${#files[@]}" '
  BEGIN { RS = ">"; t = 0; f = 0; e = 0; s = 0 }
  {
    i = index($0, "<testsuite")
    if (i == 0) next
    tag = substr($0, i + 10)
    if (tag != "" && tag !~ /^[ \t\r\n\/]/) next
    t += attr(tag, "tests"); f += attr(tag, "failures"); e += attr(tag, "errors"); s += attr(tag, "skipped")
  }
  END { printf "JUnit XML: %d tests, %d failures, %d errors, %d skipped in %d files\n", t, f, e, s, k }
  function attr(tag, name,   m) {
    if (match(tag, "[ \t\r\n]" name "=\"[0-9]+\"")) {
      m = substr(tag, RSTART, RLENGTH)
      sub(/^[^"]*"/, "", m); sub(/"$/, "", m)
      return m + 0
    }
    return 0
  }
' "${files[@]}"
