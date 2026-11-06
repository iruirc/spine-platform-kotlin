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
