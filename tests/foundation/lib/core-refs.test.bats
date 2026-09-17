#!/usr/bin/env bats
# The vendored copy of core's lint, run against this repository's own tree. `scripts/lint-core-refs.sh`
# reads the floor from plugin.json itself when no --ref is given, so the floor is never duplicated here.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  LINT="$ROOT/scripts/lint-core-refs.sh"
  CORE="${SPINE_TOOLKIT_CORE:-$ROOT/../spine-toolkit}"
  FLOOR="$(python3 -c 'import json,re,sys; d=json.load(open(sys.argv[1]))["dependencies"]; v=[x["version"] for x in d if x["name"]=="spine-toolkit"][0]; print(re.search(r">=\s*(\d+\.\d+\.\d+)", v).group(1))' "$ROOT/.claude-plugin/plugin.json")"
}

@test "this platform's core references resolve at the declared floor" {
  [ -d "$CORE/skills" ] || skip "no spine-toolkit checkout beside this one"
  run "$LINT" "$ROOT" --core "$CORE"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# The vendored lint scans agents/ and skills/ only, and it is core's file byte for
# byte — so commands/, which names core skills too, is checked here instead.
@test "commands/ obeys the same two rules the vendored lint applies" {
  [ -d "$CORE/skills" ] || skip "no spine-toolkit checkout beside this one"
  core_skills="$(git -C "$CORE" ls-tree --name-only "$FLOOR" skills/ | sed 's|^skills/||')"
  [ -n "$core_skills" ] || { echo "no skills in $CORE at $FLOOR"; return 1; }
  bad=""
  while IFS= read -r hit; do
    name="${hit##*:}"
    if ! grep -qxF "$name" <<<"$core_skills"; then bad="$bad
$hit does not exist in spine-toolkit $FLOOR"; fi
  done < <(grep -rnoE 'spine-toolkit:[a-z][a-z0-9-]*' "$ROOT"/commands/*.md || true)
  while IFS= read -r hit; do
    name="${hit##*:}"; name="${name//\`/}"
    if grep -qxF "$name" <<<"$core_skills"; then bad="$bad
$hit is a core skill written bare; write it spine-toolkit:$name"; fi
  done < <(grep -rnoE '`[a-z][a-z0-9]*(-[a-z0-9]+)+`' "$ROOT"/commands/*.md || true)
  [ -z "$bad" ] || { echo "$bad"; return 1; }
}
