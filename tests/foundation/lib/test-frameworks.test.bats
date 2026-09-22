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

TESTERS="kotlin-jvm-tester kotlin-server-tester kotlin-ui-tester kotlin-kmp-tester"

# The block every tester carries: from `## Hard Rules` to the first H2 that is not shared.
common_block() {
  awk '/^## /{ shared = ($0=="## Hard Rules" || $0=="## Test Structure" || $0=="## Mocking Policy" \
                         || $0=="## Environment Cleanup" || $0=="## Coroutines")
               if (!f && shared) f = 1
               else if (f && !shared) exit }
       f' "$1"
}

@test "the four testers carry one byte-identical copy of the shared block" {
  # Both sides go through the same extraction: comparing against a captured string
  # would compare a stripped trailing blank line, and report a difference nobody made.
  ref="$ROOT/agents/kotlin-jvm-tester.md"
  n="$(common_block "$ref" | wc -l | tr -d ' ')"
  [ "$n" -ge 80 ] || { echo "the block extraction went vacuous: $n line(s)"; return 1; }
  for a in $TESTERS; do
    diff <(common_block "$ref") <(common_block "$ROOT/agents/$a.md") \
      || { echo "$a's copy of the shared block differs"; return 1; }
  done
}

@test "the shared block names no lifecycle hook of any framework" {
  # Below this block each tester keeps the constructs its own surface forces — a Compose rule is
  # JUnit4 whatever the axis says. Inside it, a hook is one framework taught as the default.
  for a in $TESTERS; do
    hits="$(common_block "$ROOT/agents/$a.md" \
              | grep -oE '@BeforeEach|@AfterEach|@BeforeAll|@AfterAll|@Before\b|@After\b|beforeTest|afterTest' \
              | sort -u | tr '\n' ' ')"
    [ -z "$hits" ] || { echo "$a's shared block still teaches: $hits"; return 1; }
  done
}

@test "the shared block says which framework its examples are written in" {
  for a in $TESTERS; do
    common_block "$ROOT/agents/$a.md" | grep -qF 'The examples in this section are JUnit5.' \
      || { echo "$a's examples claim to be framework-neutral and are not"; return 1; }
  done
}

@test "the jvm tester no longer carries a paragraph per axis value" {
  f="$ROOT/agents/kotlin-jvm-tester.md"
  notes="$(awk '$0=="## Framework Notes"{f=1;next} f&&/^## /{exit} f' "$f")"
  [ -n "$notes" ] || { echo "no ## Framework Notes section"; return 1; }
  hits="$(grep -oE '^- \*\*(JUnit5|JUnit4|Kotest)\*\*' <<<"$notes" | tr '\n' ' ')"
  [ -z "$hits" ] || { echo "the axis values are still explained here: $hits"; return 1; }
  grep -qF '`test-frameworks`' <<<"$notes" || { echo "and nothing points at where they went"; return 1; }
  grep -qF '**MockK**' <<<"$notes" || { echo "the tooling that is not an axis value was lost too"; return 1; }
}

@test "the server tester says what each axis value does to a server environment" {
  f="$ROOT/agents/kotlin-server-tester.md"
  body="$(awk '$0=="### Framework Wiring"{f=1;next} f&&/^#{2,3} /{exit} f' "$f")"
  [ -n "$body" ] || { echo "no ### Framework Wiring section"; return 1; }
  for v in JUnit5 JUnit4 Kotest; do
    grep -qF "$v" <<<"$body" || { echo "the table has no $v column"; return 1; }
  done
  for env in 'SpringExtension' 'Testcontainers' 'testApplication'; do
    grep -qF "$env" <<<"$body" || { echo "no row for $env"; return 1; }
  done
}
