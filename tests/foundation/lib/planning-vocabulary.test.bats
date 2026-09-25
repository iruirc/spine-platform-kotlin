#!/usr/bin/env bats
# These phrases promise a release, a command or a skill this plugin never shipped; its reader cannot
# tell a plan from a feature.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
}

@test "no planning vocabulary reaches a skill, agent, command or the README" {
  n="$(ls "$ROOT"/skills/*/SKILL.md | wc -l | tr -d ' ')"
  [ "$n" -ge 25 ] || { echo "found $n SKILL.md files; the scan went vacuous"; return 1; }
  hits="$(cd "$ROOT" && grep -rniE 'in a later release|a later command|future skill|territory, later' \
    skills agents commands README.md || true)"
  [ -z "$hits" ] || { echo "$hits"; return 1; }
}
