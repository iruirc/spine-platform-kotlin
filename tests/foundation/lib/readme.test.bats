#!/usr/bin/env bats
# README.md restates two facts other files own — the core range in plugin.json and the manifest's
# tables — and nothing moves the copy when the owner changes.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
}

@test "the README quotes the core range plugin.json declares" {
  run python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["dependencies"]; print([x["version"] for x in d if x["name"]=="spine-toolkit"][0])' "$ROOT/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qF -- "- \`spine-toolkit\` \`$output\`" "$ROOT/README.md" || { echo "README does not quote $output"; return 1; }
}

@test "the README's manifest table names every table the manifest declares" {
  declared="$(grep -E '^## ' "$ROOT/skills/manifest/SKILL.md" | LC_ALL=C sort)"
  listed="$(grep -oE '^\| `## [^`]+`' "$ROOT/README.md" | sed 's/^| `//; s/`$//' | LC_ALL=C sort)"
  [ "$declared" = "$listed" ] || {
    echo "assumption violated: the README's manifest table does not list exactly the manifest's H2s"
    printf 'manifest:\n%s\nREADME:\n%s\n' "$declared" "$listed"
    return 1
  }
}

@test "every skill directory is named somewhere in the README" {
  n="$(ls "$ROOT/skills" | wc -l | tr -d ' ')"
  [ "$n" -ge 25 ] || { echo "found $n skills; the scan went vacuous"; return 1; }
  missing=""
  for s in $(ls "$ROOT/skills"); do
    grep -qF -- "$s" "$ROOT/README.md" || missing="$missing $s"
  done
  [ -z "$missing" ] || { echo "skills missing from README.md:$missing"; return 1; }
}
