#!/usr/bin/env bats
# The vendored copy of core's lint, run against this repository's own tree at the
# floor plugin.json declares. `--ref` makes the run exact rather than degrading to
# whatever the checkout happens to sit on.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  LINT="$ROOT/scripts/lint-core-refs.sh"
  CORE="${SPINE_TOOLKIT_CORE:-$ROOT/../spine-toolkit}"
}

@test "this platform's core references resolve at the declared floor" {
  [ -d "$CORE/skills" ] || skip "no spine-toolkit checkout beside this one"
  run "$LINT" "$ROOT" --core "$CORE" --ref 1.5.0
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# The vendored lint scans agents/ and skills/ only, and it is core's file byte for
# byte — so commands/, which names core skills too, is checked here instead.
@test "commands/ obeys the same two rules the vendored lint applies" {
  [ -d "$CORE/skills" ] || skip "no spine-toolkit checkout beside this one"
  core_skills="$(git -C "$CORE" ls-tree --name-only 1.5.0 skills/ | sed 's|^skills/||')"
  [ -n "$core_skills" ] || { echo "no skills in $CORE at 1.5.0"; return 1; }
  bad=""
  while IFS= read -r hit; do
    name="${hit##*:}"
    if ! grep -qxF "$name" <<<"$core_skills"; then bad="$bad
$hit does not exist in spine-toolkit 1.5.0"; fi
  done < <(grep -rnoE 'spine-toolkit:[a-z][a-z0-9-]*' "$ROOT"/commands/*.md || true)
  while IFS= read -r hit; do
    name="${hit##*:}"; name="${name//\`/}"
    if grep -qxF "$name" <<<"$core_skills"; then bad="$bad
$hit is a core skill written bare; write it spine-toolkit:$name"; fi
  done < <(grep -rnoE '`[a-z][a-z0-9]*(-[a-z0-9]+)+`' "$ROOT"/commands/*.md || true)
  [ -z "$bad" ] || { echo "$bad"; return 1; }
}
