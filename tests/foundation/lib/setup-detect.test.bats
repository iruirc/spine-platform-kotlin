#!/usr/bin/env bats
# Milestone 7: kotlin-setup asked every stack axis of a project whose build already said it, and
# offered JUnit5 first where libs.versions.toml carried junit:junit and the tests imported
# org.junit.Test. The heuristics that pin those values existed; setup never applied them.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  S="$ROOT/skills/kotlin-setup/SKILL.md"
}

@test "setup reads the build, the catalog and the sources before it asks" {
  step="$(awk '/^2b\. /{on=1} on && /^3\. /{exit} on' "$S")"
  [ -n "$step" ] || { echo "no step 2b"; return 1; }
  for s in '## Heuristics' 'gradle/libs.versions.toml' '`src/`' 'it is not asked' 'Run nothing to detect'; do
    grep -qF -- "$s" <<<"$step" || { echo "step 2b lacks: $s"; return 1; }
  done
}

@test "a catalog entry reads as the import it names, junit:junit as JUnit4" {
  grep -qF '`junit:junit` is `org.junit.Test`' "$S"
  grep -qF '`org.junit.jupiter:*` is' "$S"
}

@test "a conflict or a computed value is asked, with what the project shows first" {
  grep -qF 'offering the' "$S" && grep -qF 'values seen first' "$S"
  grep -qF 'minSdk' "$S"
  grep -qF 'with that value' "$S"
}

@test "what setup detected is reported once" {
  grep -qF '`report_axes_detected`' "$S"
  for l in en ru; do
    grep -A1 -x '## report_axes_detected' "$ROOT/skills/kotlin-setup/locales/$l.md" | grep -qF '{lines}' \
      || { echo "$l lacks the key"; return 1; }
  done
}
