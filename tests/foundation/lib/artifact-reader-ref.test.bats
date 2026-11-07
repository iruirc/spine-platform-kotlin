#!/usr/bin/env bats
# Every agent whose body tells it to keep prose concise also tells it where the
# exception lives: task artifacts follow the core artifact-reader skill. A platform
# names a core skill only by its namespaced name.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
}

@test "every agent that says 'Keep prose concise' names spine-toolkit:artifact-reader" {
  n=0
  for f in "$ROOT"/agents/*.md; do
    grep -qF 'Keep prose concise' "$f" || continue
    n=$((n + 1))
    grep -qF 'spine-toolkit:artifact-reader' "$f" \
      || { echo "$(basename "$f") says 'Keep prose concise' but never names spine-toolkit:artifact-reader"; return 1; }
  done
  # A floor, so an empty glob cannot pass.
  [ "$n" -ge 14 ] || { echo "only $n agent files carry 'Keep prose concise', expected at least 14"; return 1; }
}

@test "the added sentence follows the brevity sentence verbatim" {
  n=0
  for f in "$ROOT"/agents/*.md; do
    grep -qF 'Keep prose concise' "$f" || continue
    n=$((n + 1))
    grep -qF 'so the output can be merged or updated across stages. Artifacts named in `spine-toolkit:artifact-reader` follow its Style instead; there, brevity means no padding, not compression.' "$f" \
      || { echo "$(basename "$f"): the artifact-reader sentence is missing or altered"; return 1; }
  done
  [ "$n" -ge 14 ] || { echo "only $n agent files carry 'Keep prose concise', expected at least 14"; return 1; }
}

@test "kotlin-reviewer keeps its own closing sentence after the added one" {
  grep -qF 'not compression. Keep findings concrete (file:line) and actionable.' "$ROOT/agents/kotlin-reviewer.md" \
    || { echo "kotlin-reviewer: the added sentence does not sit before 'Keep findings concrete'"; return 1; }
}

# The Russian lines are spelled as UTF-8 bytes: a test file is not a place the i18n lint lets Cyrillic in.
@test "the i18n example shows an identifier as a reference and names the skill namespaced" {
  f="$ROOT/conventions/i18n.md"
  bad="$(printf '`FooDataProvider` \xd0\xbf\xd0\xb5\xd1\x80\xd0\xb5\xd0\xb2\xd0\xb5\xd0\xb4\xd1\x91\xd0\xbd')"
  line1="$(printf '\xd0\x98\xd1\x81\xd1\x82\xd0\xbe\xd1\x87\xd0\xbd\xd0\xb8\xd0\xba \xd0\xb4\xd0\xb0\xd0\xbd\xd0\xbd\xd1\x8b\xd1\x85 \xd1\x81\xd0\xbf\xd0\xb8\xd1\x81\xd0\xba\xd0\xb0 (`FooDataProvider`) \xd1\x82\xd0\xb5\xd0\xbf\xd0\xb5\xd1\x80\xd1\x8c \xd1\x81\xd1\x82\xd1\x80\xd0\xbe\xd0\xb8\xd1\x82\xd1\x81\xd1\x8f \xd0\xb8\xd0\xb7 \xd0\xbc\xd0\xbe\xd0\xb4\xd0\xb5\xd0\xbb\xd0\xb8.')"
  line2="$(printf '\xd0\x9f\xd0\xbe\xd1\x8d\xd1\x82\xd0\xbe\xd0\xbc\xd1\x83 \xd0\xb2\xd1\x8b\xd0\xb4\xd0\xb5\xd0\xbb\xd0\xb5\xd0\xbd\xd0\xb8\xd0\xb5 \xd0\xb1\xd0\xbe\xd0\xbb\xd1\x8c\xd1\x88\xd0\xb5 \xd0\xbd\xd0\xb5 \xd1\x82\xd0\xb5\xd1\x80\xd1\x8f\xd0\xb5\xd1\x82\xd1\x81\xd1\x8f \xd0\xbf\xd1\x80\xd0\xb8 \xd0\xbe\xd0\xb1\xd0\xbd\xd0\xbe\xd0\xb2\xd0\xbb\xd0\xb5\xd0\xbd\xd0\xb8\xd0\xb8 \xd1\x81\xd0\xbf\xd0\xb8\xd1\x81\xd0\xba\xd0\xb0.   <- RU prose (project language)')"
  if grep -qF -- "$bad" "$f"; then echo "i18n.md still makes an identifier the subject"; return 1; fi
  grep -qxF -- "$line1" "$f" || { echo "first example line missing"; return 1; }
  grep -qxF -- "$line2" "$f" || { echo "second example line missing"; return 1; }
  grep -qF '`spine-toolkit:artifact-reader`' "$f" || { echo "i18n.md never names spine-toolkit:artifact-reader"; return 1; }
}

# The ManualChecks passage of a validator: from its "### `ManualChecks.md`" heading to the next heading.
manual_checks_passage() {
  awk '/^### `ManualChecks\.md`/ { on = 1; print; next } on && /^##(#)? / { exit } on { print }' "$1"
}

@test "every validator's ManualChecks passage names the manual-checks skill and its reader, a tester" {
  for f in "$ROOT"/agents/*-validator.md; do
    p="$(manual_checks_passage "$f")"
    [ -n "$p" ] || { echo "$(basename "$f"): no ManualChecks.md passage found"; return 1; }
    grep -qF 'spine-toolkit:manual-checks' <<<"$p" || { echo "$(basename "$f"): the passage does not name spine-toolkit:manual-checks"; return 1; }
    grep -qF 'The reader is a tester who knows the product but not the code and was not on this task' <<<"$p" \
      || { echo "$(basename "$f"): the passage does not state its reader: a tester who knows the product but not the code"; return 1; }
  done
}

@test "every validator's ManualChecks passage says where the visible text of the app lives" {
  for f in "$ROOT"/agents/*-validator.md; do
    p="$(manual_checks_passage "$f")"
    grep -qF 'strings.xml' <<<"$p" \
      || { echo "$(basename "$f"): the ManualChecks passage never names strings.xml"; return 1; }
  done
}

@test "every validator's ManualChecks passage sends the lint findings back to the writer once" {
  for f in "$ROOT"/agents/*-validator.md; do
    p="$(manual_checks_passage "$f")"
    grep -qF 'lint-manual-checks.sh' <<<"$p" || { echo "$(basename "$f"): the passage never names lint-manual-checks.sh"; return 1; }
    grep -qF 'back to the writer once' <<<"$p" || { echo "$(basename "$f"): the findings do not go back to the writer once"; return 1; }
  done
}

@test "no validator still describes ManualChecks in the old format" {
  for f in "$ROOT"/agents/*-validator.md; do
    p="$(manual_checks_passage "$f")"
    for old in 'two rules that make a case executable' 'two rules that decide' 'By eye' 'Scene' 'code reference per case' 'hand-run script' 'a person'; do
      if grep -qF -- "$old" <<<"$p"; then echo "$(basename "$f"): the ManualChecks passage still says '$old'"; return 1; fi
    done
    if grep -qF 'hand-run script' "$f"; then echo "$(basename "$f"): still calls ManualChecks the 'hand-run script'"; return 1; fi
  done
}

@test "no validator names the lint by a bare core path" {
  for f in "$ROOT"/agents/*-validator.md; do
    if grep -qE '(^|[^[:alnum:]_.-])(\.\./)?(scripts|skills)/(lint-manual-checks|manual-checks|artifact-reader)' "$f"; then
      echo "$(basename "$f"): names a core path bare"; return 1
    fi
  done
}

@test "the toolkit floor is at least the release that ships artifact-reader" {
  grep -qF '"version": ">=2.30.0 <3"' "$ROOT/.claude-plugin/plugin.json" \
    || { echo "plugin.json floor is not >=2.30.0 <3"; return 1; }
}

@test "no validator's MANUAL_CHECKS axis row still promises a human a script" {
  for f in "$ROOT"/agents/*-validator.md; do
    grep -qF '| `[MANUAL_CHECKS]` | `auto` | whether a tester gets test cases |' "$f" \
      || { echo "$(basename "$f"): the [MANUAL_CHECKS] axis row does not say 'whether a tester gets test cases'"; return 1; }
  done
  if grep -rqF -e 'gets a script' -e 'hand-run script' "$ROOT/agents" "$ROOT/skills" "$ROOT/README.md"; then
    echo "an agent, skill or the README still says 'gets a script' or 'hand-run script'"; return 1
  fi
}

@test "the README and kotlin-diagnostics use the QA test-case wording" {
  grep -qF 'the checks become test cases' "$ROOT/README.md" || { echo "README: the deferred checks are not test cases"; return 1; }
  grep -qF 'a tester runs by hand.' "$ROOT/README.md" || { echo "README: no 'a tester runs by hand'"; return 1; }
  if grep -qF 'executable as the skill defines it' "$ROOT/agents/kotlin-diagnostics.md"; then
    echo "kotlin-diagnostics still says 'executable as the skill defines it'"; return 1
  fi
  grep -qF "must follow the skill's case format" "$ROOT/agents/kotlin-diagnostics.md" \
    || { echo "kotlin-diagnostics: the case-format wording is missing"; return 1; }
}
