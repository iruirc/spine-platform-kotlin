#!/usr/bin/env bats
# changed: sweep skills agents conventions commands
# The config's settings live in [FIELD] = [value] lines. A surface still telling a reader to find
# a `## <Block>` section of that file is a surface that will send them looking for something the
# file no longer has.

setup() { ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"; }

# Core's helper (tests/foundation/lib/config-format.test.bats there), plus one exemption core has
# no occasion for: every mention of the config's `## <block>` in $2, minus the headings of $2 that
# merely begin with that word, and minus the two contract sections quoted in prose that are not the
# config's — `## Language Resolution`, which every localized skill carries, and `## Validation
# Report`, a section of a tester agent's own reply.
mentions() {
  command grep -nE "(^|[^#])## $1([^A-Za-z]|\$)" "$2" \
    | command grep -vE "## Language Resolution|## Validation Report|^[0-9]+:#+ $1 [A-Za-z]"
}

# Prints each mention of `## $1` in $2 as `<file>:<line>: <text>`, then the hint, and returns 1; returns 0
# when there is none. A finding that only says "still names" leaves the reader to guess what to write instead.
report_mentions() {
  local found l
  found="$(mentions "$1" "$2")" || true
  [ -n "$found" ] || return 0
  while IFS= read -r l; do printf '%s:%s: %s\n' "$2" "${l%%:*}" "${l#*:}"; done <<<"$found"
  printf 'hint: "## %s" reads as a section of the config, and the config has no such section any more: its settings are [FIELD] = [value] lines. Name a stage without "##" (the Validation stage) and a task file as Validation.md.\n' "$1"
  return 1
}

@test "a mention of a moved block prints the line and the hint" {
  printf '%s\n' 'see ## Validation for the setting' >"$BATS_TEST_TMPDIR/x.md"
  run report_mentions Validation "$BATS_TEST_TMPDIR/x.md"
  [ "$status" -eq 1 ]
  # `[[ ]]` mid-test does not fail a test under bash 3.2, so assert with grep.
  grep -qF -- 'x.md:1: see ## Validation for the setting' <<<"$output"
  grep -qF -- 'hint: "## Validation" reads as a section of the config, and the config has no such section any more: its settings are [FIELD] = [value] lines. Name a stage without "##" (the Validation stage) and a task file as Validation.md.' <<<"$output"
  printf '%s\n' "the ## Validation Report section" >"$BATS_TEST_TMPDIR/x.md"
  run report_mentions Validation "$BATS_TEST_TMPDIR/x.md"
  [ "$status" -eq 0 ]
}

@test "no surface of this platform names a moved block of the project config" {
  n=0
  while IFS= read -r f; do
    n=$((n + 1))
    for block in Language Mode Progress Scale Reporting Validation Docs Budgets Models Effort; do
      report_mentions "$block" "$f" || return 1
    done
  done < <(find "$ROOT/skills" "$ROOT/agents" "$ROOT/conventions" "$ROOT/commands" "$ROOT/tests" \
             -name '*.md' -o -name '*.bash')
  [ "$n" -ge 30 ] || { echo "scanned $n file(s), expected at least 30"; return 1; }
}

# No extension filter: the vendored lints are `.sh` and one workspace script is `.zsh`, and
# enumerating suffixes is how a script lands outside the only guard that would have caught it.
@test "no script of this platform names a moved block of the project config" {
  n=0
  while IFS= read -r f; do
    n=$((n + 1))
    for block in Language Mode Progress Scale Reporting Validation Docs Budgets Models Effort; do
      report_mentions "$block" "$f" || return 1
    done
  done < <(find "$ROOT/scripts" -type f)
  [ "$n" -ge 5 ] || { echo "scanned $n file(s), expected at least 5"; return 1; }
}
