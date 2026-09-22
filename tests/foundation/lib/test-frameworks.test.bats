#!/usr/bin/env bats
# The axis named a framework and four testers wrote JUnit5 regardless. The syntax now lives once,
# keyed by the axis value, and these tests hold the two halves together: every value has a section,
# every section has a value, and every section has the same seven subsections.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SKILL="$ROOT/skills/test-frameworks/SKILL.md"
  MANIFEST="$ROOT/skills/manifest/SKILL.md"
}

# The values of one manifest axis, one per line.
axis_values() { # $1 = axis name
  sed -n "s/^$1 *= *//p" "$MANIFEST" | tr ',' '\n' | sed 's/^ *//; s/ *$//'
}

# The H2s of a file, fences excluded.
h2s() {
  awk '/^[ \t]*(```|~~~)/ {fence = !fence; next} !fence && /^## / {sub(/^## /, ""); print}' "$1"
}

@test "the skill exists and resolves under its own name" {
  [ -f "$SKILL" ] || { echo "no skills/test-frameworks/SKILL.md"; return 1; }
  grep -q '^name: test-frameworks$' "$SKILL" || { echo "frontmatter name is not test-frameworks"; return 1; }
}

@test "every value of the tests axis has a section" {
  n=0
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    n=$((n + 1))
    h2s "$SKILL" | grep -qxF -- "$v" || { echo "no '## $v' section for axis value $v"; return 1; }
  done < <(axis_values tests)
  [ "$n" -ge 3 ] || { echo "found $n values of the tests axis; the scan went vacuous"; return 1; }
}

@test "every framework section of the skill is a value of the tests axis" {
  # Skeleton B's own sections are not framework sections; everything else must be a value,
  # so a framework dropped from the axis cannot leave a section behind.
  values="$(axis_values tests)"
  while IFS= read -r h; do
    case "$h" in "When to Use"|"Common Mistakes"|"Forced by surface") continue ;; esac
    grep -qxF -- "$h" <<<"$values" || { echo "'## $h' is no value of the tests axis"; return 1; }
  done < <(h2s "$SKILL")
}

@test "every framework section carries all seven subsections" {
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    body="$(awk -v h="## $v" '$0==h{f=1;next} f&&/^## /{exit} f' "$SKILL")"
    for sub in Declaration Assertions Lifecycle Parameterization Async "Failure output" Setup; do
      grep -qxF "### $sub" <<<"$body" || { echo "## $v has no '### $sub'"; return 1; }
    done
  done < <(axis_values tests)
}

@test "the skill lists the surfaces that force a framework" {
  h2s "$SKILL" | grep -qxF 'Forced by surface' || { echo "no '## Forced by surface'"; return 1; }
  body="$(awk '$0=="## Forced by surface"{f=1;next} f&&/^## /{exit} f' "$SKILL")"
  for surface in 'createComposeRule()' 'Robolectric' 'androidInstrumentedTest' 'commonTest'; do
    grep -qF "$surface" <<<"$body" || { echo "the $surface surface is not named"; return 1; }
  done
}

@test "the manifest answers the testing topic with this skill" {
  grep -qE '^testing[[:space:]]*→[[:space:]]*`test-frameworks`$' "$MANIFEST" \
    || { echo "no testing row in the manifest ## Topics"; return 1; }
}
