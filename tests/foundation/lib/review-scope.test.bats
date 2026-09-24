#!/usr/bin/env bats
# Inside a task, what the reviewer reads is decided by core and handed over; the agent must
# not fall back to deriving it from one repository's HEAD.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  A="$ROOT/agents/kotlin-reviewer.md"
  CORE="${SPINE_TOOLKIT_CORE:-$ROOT/../spine-toolkit}"
}

@test "the reviewer reviews the ranges its task prompt names" {
  grep -qF 'Review exactly those ranges' "$A" || { echo "Identify Scope does not take the ranges"; return 1; }
  grep -qF '`conventions/task-ranges.md`' "$A" || { echo "no pointer to the convention"; return 1; }
  if grep -qF 'Get it with `git rev-parse HEAD`' "$A"; then echo "the record is still one repository's HEAD"; return 1; fi
  grep -qF '`## For Done`' "$A" || { echo "the template has no ## For Done"; return 1; }
}

@test "core at the declared floor has the convention the reviewer points at" {
  floor="$(python3 -c 'import json,sys,re; d=json.load(open(sys.argv[1]))["dependencies"]; v=[x["version"] for x in d if x["name"]=="spine-toolkit"][0]; print(re.search(r">=\s*(\d+\.\d+\.\d+)", v).group(1))' "$ROOT/.claude-plugin/plugin.json")"
  git -C "$CORE" rev-parse -q --verify "$floor^{commit}" >/dev/null || skip "core has no tag $floor"
  git -C "$CORE" cat-file -e "$floor:conventions/task-ranges.md" || { echo "core $floor has no conventions/task-ranges.md — the floor is too low"; return 1; }
}
