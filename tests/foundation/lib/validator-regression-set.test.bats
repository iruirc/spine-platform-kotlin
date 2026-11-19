#!/usr/bin/env bats
# changed: sweep
# Validation runs the task's regression set, not every test task the build declares: each validator
# finds the changed modules, their dependents and the app that ships them, runs those, and records the
# set in Validation.md for core's lint. The reviewer reads that record instead of re-running the suites.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  VALIDATORS="kotlin-jvm-validator kotlin-server-validator kotlin-ui-validator"
  R="$ROOT/agents/kotlin-reviewer.md"
}

# Run a check over every validator and name the one that fails it.
each() {
  local v
  for v in $VALIDATORS; do
    V="$ROOT/agents/$v.md"
    "$@" || { echo "$v: $*"; return 1; }
  done
}

has_step_before_profiles() {
  grep -qF '### Regression set' "$V" || { echo "no ### Regression set"; return 1; }
  [ "$(grep -n '^### Regression set' "$V" | head -1 | cut -d: -f1)" -lt "$(grep -n '^### FEATURE' "$V" | head -1 | cut -d: -f1)" ] || { echo "the step comes after the profiles"; return 1; }
}

@test "each validator has a Regression set step before the profiles" {
  each has_step_before_profiles
}

finds_modules_through_gradle() {
  grep -qF 'settings.gradle' "$V" || { echo "no settings.gradle"; return 1; }
  grep -qF 'includeBuild' "$V" || { echo "no includeBuild"; return 1; }
  grep -qF 'project(":' "$V" || { echo 'no project(":'; return 1; }
  grep -qF 'composite-build' "$V" || { echo "no composite-build substitutions"; return 1; }
}

@test "the set is found through project dependencies and composite builds, never published versions" {
  each finds_modules_through_gradle
}

defers_to_core() {
  grep -qF "Validation's regression" "$V" || { echo "no pointer to core's section"; return 1; }
  grep -qF 'validation_ranges' "$V" || { echo "no validation_ranges"; return 1; }
  grep -qF 'task-ranges.sh ranges' "$V" || { echo "no fallback to task-ranges.sh"; return 1; }
  grep -qF 'Search roots:' "$V" || { echo "modules are not looked for under the brief's search roots"; return 1; }
  grep -qF '`rewritten`' "$V" || { echo "no rule for an unknown or rewritten range"; return 1; }
  grep -qF 'the app runs too' "$V" || { echo "the app does not join a re-run"; return 1; }
}

@test "each validator defers the definition of the set to core" {
  each defers_to_core
}

records_and_lints() {
  grep -qF '## Regression set' "$V" || { echo "no ## Regression set in the template"; return 1; }
  grep -qF 'lint-validation-scope.sh' "$V" || { echo "no lint"; return 1; }
  grep -qF 'carried' "$V" || { echo "no carried rows"; return 1; }
  grep -qF -- '--kind validated' "$V" || { echo "no validated tips in the closing block"; return 1; }
  sed -n '/^## Self-Verification/,/^## What You Never Do/p' "$V" | grep -qF 'lint-validation-scope.sh' || { echo "no checkbox for the lint"; return 1; }
}

@test "each validator records the set and lints it before returning" {
  each records_and_lints
}

runs_the_set_only() {
  grep -qF ':a:<task> :b:<task>' "$V" || { echo "no per-module gradlew line"; return 1; }
  if grep -qF 'no existing tests may break' "$V"; then echo "BUG rule still names every test"; return 1; fi
  grep -qF 'no test of the regression set may break' "$V" || { echo "BUG rule does not name the set"; return 1; }
  grep -qF 'Every pre-existing test of the regression set' "$V" || { echo "REFACTOR rule does not name the set"; return 1; }
  grep -qF 'owner asks' "$V" || { echo "no owner rule for the whole-build script"; return 1; }
}

@test "no profile rule runs every test of the build" {
  each runs_the_set_only
}

@test "the reviewer points at the lint first" {
  grep -qF 'lint-validation-scope.sh' "$R" || { echo "no lint in the reviewer"; return 1; }
  grep -qF '### Regression set' "$R" || { echo "the reviewer does not point at the validator's recipe"; return 1; }
}
