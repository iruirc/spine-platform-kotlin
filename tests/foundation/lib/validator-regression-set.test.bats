#!/usr/bin/env bats
# changed: sweep agents
# Validation runs the task's regression set, not every test task the build declares: each validator
# finds the changed modules, their dependents and the app that ships them, runs those, and records the
# set in Validation.md for core's lint. The reviewer reads that record instead of re-running the suites.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  VALIDATORS="kotlin-jvm-validator kotlin-server-validator kotlin-ui-validator"
  R="$ROOT/agents/kotlin-reviewer.md"
  CORE="${SPINE_TOOLKIT_CORE:-$ROOT/../spine-toolkit}"
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

addresses_every_build_the_set_lives_in() {
  grep -qF ':<included-build>:<module>:<task>' "$V" || { echo "no included-build addressing"; return 1; }
  grep -qF 'its own `./gradlew`' "$V" || { echo "no run from the checkout's own root"; return 1; }
  grep -qF "type-safe accessor" "$V" || { echo "dependents only by the literal project(\":x\")"; return 1; }
  grep -qF 'Amper build' "$V" || { echo "no Amper rule"; return 1; }
}

@test "the run reaches included builds and sibling checkouts, and every build tool is scoped" {
  each addresses_every_build_the_set_lives_in
}

maven_is_scoped() {
  local bad
  bad="$(grep -n 'mvn -B' "$V" | grep -v -e '-pl <modules>' || true)"
  [ -z "$bad" ] || { echo "a Maven form runs the whole reactor: $bad"; return 1; }
  grep -qF "parent POM" "$V" || { echo "no shared-file rule for Maven"; return 1; }
  grep -qF 'mvn -B -DskipTests -pl <modules> -amd verify' "$V" || { echo "the build step is not scoped"; return 1; }
  grep -qF 'mvn -B -pl <modules> -amd verify' "$V" || { echo "the test step is not scoped"; return 1; }
}

@test "the Maven forms of the jvm and server validators run the set's modules, build and test apart" {
  for v in kotlin-jvm-validator kotlin-server-validator; do
    V="$ROOT/agents/$v.md"
    maven_is_scoped || { echo "$v"; return 1; }
  done
}

@test "a re-run carries a BUG replay the commits do not reach, and says which Validation it comes from" {
  for v in kotlin-server-validator kotlin-ui-validator; do
    V="$ROOT/agents/$v.md"
    grep -qF 'the replay is carried from the last green Validation' "$V" || { echo "$v: no carried replay"; return 1; }
    grep -qF 'otherwise `deferred-manual`' "$V" || { echo "$v: the carried status is not stated"; return 1; }
  done
}

no_source_names_its_module() {
  grep -qF 'FAILED for the module that holds the added tests' "$V"
}

@test "the TEST profile fails NO-SOURCE only for the module that holds the added tests" {
  each no_source_names_its_module
}

@test "the reviewer points at the lint first" {
  grep -qF 'lint-validation-scope.sh' "$R" || { echo "no lint in the reviewer"; return 1; }
  grep -qF '### Regression set' "$R" || { echo "the reviewer does not point at the validator's recipe"; return 1; }
}

amper_runs_the_set_and_the_app_is_found_in_every_form() {
  grep -qF 'over the modules of the set per `### Regression set` item 4' "$V" || { echo "the Amper reading bullet runs the whole build"; return 1; }
  grep -qF 'among its project dependencies, in any form item 2 lists' "$V" || { echo "the app is found only through project(\":x\")"; return 1; }
  if grep -qF 'among its `project(":x")` dependencies' "$V"; then echo "item 3 still names only project(\":x\")"; return 1; fi
  [ "$(grep -c 'rows of one command share' "$V")" -eq 1 ] || { echo "the log-sharing rule is stated more than once"; return 1; }
  grep -qF 'uncommitted edits reaching their module too' "$V" || { echo "a re-run ignores uncommitted edits"; return 1; }
}

@test "Amper runs the modules of the set, the app joins through any dependency form, and a re-run counts uncommitted edits" {
  each amper_runs_the_set_and_the_app_is_found_in_every_form
}

outside_follows_core_and_flaky_stays_with_test() {
  grep -qF '`spine-toolkit:phase-verification`' "$V" || { echo "no pointer to phase-verification"; return 1; }
  grep -qF 'Failures outside the task' "$V" || { echo "no pointer to the subsection"; return 1; }
  grep -qF '## Outside the task' "$V" || { echo "no ## Outside the task"; return 1; }
  grep -qF 'known_failures' "$V" || { echo "no registry field"; return 1; }
  ! grep -qF 'FLAKY — TEST-profile only; one or more new tests showed' "$V" || { echo "FLAKY keeps the old wording"; return 1; }
  grep -qF 'FLAKY** — TEST-profile only; a test the task added' "$V" || { echo "FLAKY is not tied to the tests the task added"; return 1; }
  local flaky
  flaky="$(sed -n '/^- \*\*Flaky detection\*\*/p' "$V")"
  grep -qF 'a test the task added' <<<"$flaky" || { echo "flaky detection is not about the added tests"; return 1; }
  grep -qF 'outside the task' <<<"$flaky" || { echo "flaky detection does not leave outside failures to core's rule"; return 1; }
  sed -n '/^## Flaky Detection (TEST profile)/,/^## Skills Reference/p' "$V" | grep -qF 'a failing test the task did not add is not this section' || { echo "the Flaky Detection section is not limited to the added tests"; return 1; }
}

@test "failures outside the task follow core's rule, and FLAKY stays the TEST profile's" {
  each outside_follows_core_and_flaky_stays_with_test
}

return_carries_the_new_status_and_fields() {
  grep -qxF '[VALIDATION_STATUS] = PASSED_WITH_FLAKES' "$V" || { echo "no PASSED_WITH_FLAKES status line"; return 1; }
  grep -qF '[VALIDATION_STATUS] = PASSED | PASSED_WITH_FLAKES | FAILED | FLAKY' "$V" || { echo "the return line lacks the four values"; return 1; }
  grep -qF 'Exactly one of the four values' "$V" || { echo "the status rule still counts three values"; return 1; }
  grep -qF 'outside_failures:' "$V" || { echo "no outside_failures"; return 1; }
  grep -qF 'known_failures_cleared:' "$V" || { echo "no known_failures_cleared"; return 1; }
  grep -qF '{repository, module, test, outcome, entry}' "$V" || { echo "no item shape"; return 1; }
  grep -qF 'PASSED_WITH_FLAKES → `continue`' "$V" || { echo "PASSED_WITH_FLAKES does not continue"; return 1; }
  grep -qF '(`continue` for PASSED and PASSED_WITH_FLAKES, `ask_user` for FAILED/FLAKY)' "$V" || { echo "the checklist does not name PASSED_WITH_FLAKES"; return 1; }
  grep -qF 'On PASSED or PASSED_WITH_FLAKES, close the file' "$V" || { echo "tips are written on PASSED only"; return 1; }
}

@test "the return carries PASSED_WITH_FLAKES, outside_failures and known_failures_cleared" {
  each return_carries_the_new_status_and_fields
}

rerun_carries_from_phase_or_validation() {
  grep -qF 'carried <sha> (phase <N>)' "$V" || { echo "no phase source"; return 1; }
  grep -qF 'carried <sha> (validation)' "$V" || { echo "no validation source"; return 1; }
  grep -qF 'ran: <repository> <module> HEAD <sha> Executed <N> log phase-evidence/phase-<id>/<module>.log' "$V" || { echo "no ran: line"; return 1; }
  grep -qF 'of several sources the latest wins, and a module red in the latest Validation that ran it runs again' "$V" || { echo "no latest-wins rule"; return 1; }
  grep -qF 'A line of class `reach` is not a finding: leave it for Review.' "$V" || { echo "reach lines are not left for Review"; return 1; }
  if grep -qF 'Run` is `ran` or `carried <sha>`' "$V"; then echo "the Run column keeps the bare carried form"; return 1; fi
}

@test "a re-run carries a green module from a phase or an earlier Validation, and leaves reach lines to Review" {
  each rerun_carries_from_phase_or_validation
}

rule_two_names_the_flakes() {
  local rule2
  rule2="$(grep -F '2. **Never falsify a verdict.**' "$V")"
  grep -qF 'PASSED_WITH_FLAKES names the failures rather than hiding them' <<<"$rule2" || { echo "rule 2 has no such phrase"; return 1; }
}

@test "PASSED_WITH_FLAKES names the failures rather than hiding them" {
  each rule_two_names_the_flakes
}

@test "the toolkit floor is 2.44.0" {
  grep -qF '{ "name": "spine-toolkit", "version": ">=2.44.0 <3" }' "$ROOT/.claude-plugin/plugin.json" \
    || { echo "the spine-toolkit floor is not >=2.44.0 <3"; return 1; }
  grep -qF '`spine-toolkit` `>=2.44.0 <3`' "$ROOT/README.md" || { echo "the README floor is not >=2.44.0 <3"; return 1; }
}

statuses_follow_core() {
  local passed flakes failed
  passed="$(grep -F -- '- **PASSED** —' "$V")"
  flakes="$(grep -F -- '- **PASSED_WITH_FLAKES** —' "$V")"
  failed="$(grep -F -- '- **FAILED** —' "$V")"
  grep -qF 'all tests passed bar the failures outside the task that `### Failures outside the task` gives PASSED' <<<"$passed" || { echo "PASSED still says every test passed"; return 1; }
  grep -qF 'at least one failure outside the task, with no registry entry, failed and then passed on its retry' <<<"$flakes" || { echo "PASSED_WITH_FLAKES is not tied to a no-entry failure that passed on retry"; return 1; }
  grep -qF 'every other failure is `known`' <<<"$flakes" || { echo "no known failures beside the flake"; return 1; }
  grep -qF 'Failures that are all `known` leave PASSED' <<<"$flakes" || { echo "all-known is not PASSED"; return 1; }
  grep -qF 'a failure outside the task stayed red on its retry' <<<"$failed" || { echo "FAILED misses a red outside failure"; return 1; }
  grep -qF 'FAILED > FLAKY > PASSED_WITH_FLAKES > PASSED' "$V" || { echo "no order of statuses"; return 1; }
}

@test "PASSED allows the known failures outside the task, PASSED_WITH_FLAKES needs a flake with no entry" {
  each statuses_follow_core
}

inside_is_failed_and_registry_is_an_input() {
  grep -qF "A failure inside the task, a TEST task's added tests aside, is FAILED, whatever the registry says." "$V" || { echo "the inside rule drops the TEST exception"; return 1; }
  grep -qF 'the file the brief gives in `known_failures`' "$V" || { echo "the registry is not the brief's field"; return 1; }
  grep -qF '5. The registry of known failures' "$V" || { echo "the registry is not in the inputs"; return 1; }
  grep -qF 'you never write it' "$V" || { echo "the validator may write the registry"; return 1; }
  grep -qF 'Passed with <n> flake(s) outside the task.' "$V" || { echo "no verdict line for PASSED_WITH_FLAKES"; return 1; }
}

@test "a failure inside the task is FAILED bar a TEST task's added tests, and the registry is an input" {
  each inside_is_failed_and_registry_is_an_input
}

non_zero_test_task_is_classified() {
  grep -qF 'The exit code decides whether a step ran green' "$V" || { echo "the exit code still decides pass/fail"; return 1; }
  if grep -qF 'Exit code decides pass/fail' "$V"; then echo "the old exit-code rule remains"; return 1; fi
  grep -qF 'A test task exits non-zero on any test failure: when every failure it reports is outside the task, it is classified by core'"'"'s `### Failures outside the task` as that subsection says, not FAILED for the exit code alone.' "$V" || { echo "no classification of a non-zero test task"; return 1; }
  grep -qF 'A compile or build error is `BUILD FAILED` and FAILED' "$V" || { echo "a build error is not FAILED"; return 1; }
  local forms f
  case "$V" in
    *kotlin-jvm-validator.md) forms='./gradlew --console=plain --continue :a:test :b:test' ;;
    *kotlin-server-validator.md) forms='./gradlew --continue :a:test :b:test' ;;
    *kotlin-ui-validator.md) forms='Android `./gradlew --continue :<app>:testDebugUnitTest`|Desktop `./gradlew --continue :<app>:test`|KMP `./gradlew --continue :<module>:allTests`' ;;
  esac
  local IFS='|'
  for f in $forms; do
    grep -qF -- "$f" "$V" || { echo "the test form lacks --continue: $f"; return 1; }
  done
  grep -qF 'a retry of failures outside the task uses the same `--rerun --tests` form as `## Flaky Detection (TEST profile)`' "$V" || { echo "no retry form"; return 1; }
  if grep -qF 'every test of its regression set passes' "$V"; then echo "the role intro says every test passes"; return 1; fi
  if grep -qF 'tests of its regression set pass,' "$V"; then echo "the role intro says the tests pass"; return 1; fi
}

@test "a non-zero test task over failures outside the task is classified, not FAILED for its exit code" {
  each non_zero_test_task_is_classified
}

registry_is_untouched() {
  grep -qF 'Write the known failures registry, or report a failure outside the task as PASSED without a row for it in `## Outside the task`.' "$V" || { echo "no registry line in What You Never Do"; return 1; }
  grep -qF 'the registry is untouched' "$V" || { echo "no registry item in the checklist"; return 1; }
  sed -n '/^## Self-Verification/,/^## What You Never Do/p' "$V" | grep -qF 'the registry is untouched' || { echo "the registry item is not in Self-Verification"; return 1; }
  sed -n '/^## What You Never Do/,/^## Output Language/p' "$V" | grep -qF 'Write the known failures registry' || { echo "the registry line is not in What You Never Do"; return 1; }
}

@test "the validator never writes the registry, in the checklist and in What You Never Do" {
  each registry_is_untouched
}

@test "core at the floor has the subsection the validators point at" {
  [ -d "$CORE/.git" ] || skip "no spine-toolkit checkout beside this one"
  floor="$(python3 -c 'import json,sys,re; d=json.load(open(sys.argv[1]))["dependencies"]; v=[x["version"] for x in d if x["name"]=="spine-toolkit"][0]; print(re.search(r">=\s*(\d+\.\d+\.\d+)", v).group(1))' "$ROOT/.claude-plugin/plugin.json")"
  git -C "$CORE" rev-parse -q --verify "$floor^{commit}" >/dev/null || skip "core has no tag $floor"
  git -C "$CORE" show "$floor:skills/phase-verification/SKILL.md" | grep -qxF '### Failures outside the task' \
    || { echo "core $floor has no ### Failures outside the task — the floor is too low"; return 1; }
}
