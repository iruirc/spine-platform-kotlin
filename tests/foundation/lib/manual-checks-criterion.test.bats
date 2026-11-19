#!/usr/bin/env bats
# changed: sweep
# A deferred check becomes a case in ManualChecks.md only when it needs a person. The criterion
# is core's (spine-toolkit:manual-checks); every validator has to apply it, not restate it.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
}

# The ManualChecks passage of a validator: from its "### `ManualChecks.md`" heading to the next heading.
manual_checks_passage() {
  awk '/^### `ManualChecks\.md`/ { on = 1; print; next } on && /^##(#)? / { exit } on { print }' "$1"
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
  grep -qF '{ "name": "spine-toolkit", "version": ">=2.39.0 <3" }' "$ROOT/.claude-plugin/plugin.json" \
    || { echo "the spine-toolkit floor is not >=2.39.0 <3"; return 1; }
}

@test "the none line names what was covered and each automatable gap" {
  for a in jvm ui server; do
    grep -qF 'each automatable gap' "$ROOT/agents/kotlin-$a-validator.md" \
      || { echo "kotlin-$a-validator: gaps are lost when there is no file"; return 1; }
  done
}

@test "a test suite skipped for its environment is a gap, not a hand-run case" {
  ! grep -qF 'its case written into `ManualChecks.md`' "$ROOT/agents/kotlin-jvm-validator.md" \
    || { echo "kotlin-jvm-validator: an environment-bound test task still becomes a case"; return 1; }
  ! grep -qF 'the skipped cases go to `ManualChecks.md`' "$ROOT/agents/kotlin-server-validator.md" \
    || { echo "kotlin-server-validator: skipped suites still become cases"; return 1; }
}

@test "every validator writes code references in their own section and leaves measuring to itself" {
  for a in jvm ui server; do
    A="$ROOT/agents/kotlin-$a-validator.md"
    grep -qF '`## Code references`' "$A" || { echo "kotlin-$a-validator: still puts code in the case"; return 1; }
    ! grep -qF 'live only in `**Code:**`' "$A" || { echo "kotlin-$a-validator: the old Code field is still named"; return 1; }
    ! grep -qF 'twelve fields' "$A" || { echo "kotlin-$a-validator: the case still has twelve fields"; return 1; }
    grep -qF '## What a case must prove' "$A" || { echo "kotlin-$a-validator: no pointer to the writing rules"; return 1; }
    grep -qF 'never an instruction for a person to measure' "$A" || { echo "kotlin-$a-validator: may still hand measuring to a person"; return 1; }
  done
}

@test "every validator keeps no instrument in the file and sends measuring to Validation.md" {
  for a in jvm ui server; do
    A="$ROOT/agents/kotlin-$a-validator.md"
    ! grep -qF '**By instrument:**' "$A" || { echo "kotlin-$a-validator: the instrument field is still named"; return 1; }
    ! grep -qF 'exact invocation' "$A" || { echo "kotlin-$a-validator: the file still carries an instrument invocation"; return 1; }
    ! grep -qF 'the measuring' "$A" || { echo "kotlin-$a-validator: the measuring is still named"; return 1; }
    grep -qF 'Measurements you can take yourself go to `Validation.md`' "$A" || { echo "kotlin-$a-validator: measuring does not go to Validation.md"; return 1; }
  done
}

@test "every validator's case form follows manual_checks_style and counts no fields" {
  for a in jvm ui server; do
    A="$ROOT/agents/kotlin-$a-validator.md"
    grep -qF 'manual_checks_style' "$A" || { echo "kotlin-$a-validator: the style field is not named"; return 1; }
    grep -qF '[STYLE]' "$A" || { echo "kotlin-$a-validator: the file's style line is not named"; return 1; }
    ! grep -qF 'eleven fields' "$A" || { echo "kotlin-$a-validator: the case still has eleven fields"; return 1; }
    ! grep -qF 'five-column' "$A" || { echo "kotlin-$a-validator: the step table is still counted"; return 1; }
  done
}

@test "every validator's deferred check first passes the question about the diff" {
  for a in jvm ui server; do
    grep -qF 'Does the diff change this behaviour?' "$ROOT/agents/kotlin-$a-validator.md" \
      || { echo "kotlin-$a-validator: a deferred check skips the diff question"; return 1; }
  done
}

@test "no line outside the criterion pointer routes a deferred check to a case without the criterion" {
  for a in jvm ui server; do
    stale="$(grep -n -E 'becomes? (a )?(manual )?cases?|become manual cases' "$ROOT/agents/kotlin-$a-validator.md" | grep -vF '## Does this check need a person?' || true)"
    [ -z "$stale" ] || { echo "kotlin-$a-validator: stale routing: $stale"; return 1; }
  done
}

@test "every closing checklist names the outcome of a check the diff does not change" {
  for a in jvm ui server; do
    grep -qE '^- \[ \].*the diff does not change' "$ROOT/agents/kotlin-$a-validator.md" \
      || { echo "kotlin-$a-validator: the closing checklist has no diff-unchanged outcome"; return 1; }
  done
}

@test "the manual-checks paragraph of every validator names the skill, not an ambiguous Its" {
  for a in jvm ui server; do
    A="$ROOT/agents/kotlin-$a-validator.md"
    ! grep -qF 'Its `## What a case must prove`' "$A" || { echo "kotlin-$a-validator: ambiguous Its before the skill's section"; return 1; }
    ! grep -qF 'Its input is' "$A" || { echo "kotlin-$a-validator: ambiguous Its before the skill's input"; return 1; }
  done
}

@test "a step a validator cannot perform is deferred, not deferred to a human" {
  for a in jvm ui server; do
    ! grep -qF 'deferred to a human' "$ROOT/agents/kotlin-$a-validator.md" \
      || { echo "kotlin-$a-validator: still defers to a human"; return 1; }
  done
}

@test "the manual-checks paragraph of every validator sends a driver-only deferral to the collective pass by name" {
  for a in jvm ui server; do
    p="$(manual_checks_passage "$ROOT/agents/kotlin-$a-validator.md")"
    grep -qF '`manual_checks_pass`' <<<"$p" || { echo "kotlin-$a-validator: the paragraph does not name manual_checks_pass"; return 1; }
    grep -qF '**Runner:** agent' <<<"$p" || { echo "kotlin-$a-validator: the paragraph does not name the agent runner"; return 1; }
    grep -qF '## Marks for a collective pass' <<<"$p" || { echo "kotlin-$a-validator: the paragraph does not point at the marks section"; return 1; }
  done
}

@test "in every validator a Runner agent check stays a case and counts for writing the file" {
  for a in jvm ui server; do
    p="$(manual_checks_passage "$ROOT/agents/kotlin-$a-validator.md")"
    grep -qF 'stays a case of the file' <<<"$p" || { echo "kotlin-$a-validator: the paragraph does not keep the Runner agent check a case"; return 1; }
    grep -qF 'counts as a case when deciding whether the file is written' <<<"$p" || { echo "kotlin-$a-validator: the paragraph does not count the Runner agent check for writing the file"; return 1; }
  done
}
