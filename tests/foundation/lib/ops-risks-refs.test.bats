#!/usr/bin/env bats
# changed: sweep skills agents conventions
# The retired checklist skill and its artifact are gone from this plugin. The reviewer
# applies spine-toolkit:ops-risks at Review and the architect at Plan, and the plugin
# declares the toolkit release that has the skill.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
}

@test "no agent or skill names OpsChecklist.md or ops-checklist" {
  hits="$(cd "$ROOT" && grep -rIl -E 'OpsChecklist|ops-checklist|ops_checklist' agents skills conventions || true)"
  [ -z "$hits" ] || { echo "still named in: $hits"; return 1; }
}

@test "the reviewer applies ops-risks at Review and the architect at Plan" {
  grep -F 'spine-toolkit:ops-risks' "$ROOT/agents/kotlin-reviewer.md" | grep -qF '## Review'
  grep -F 'spine-toolkit:ops-risks' "$ROOT/agents/kotlin-architect.md" | grep -qF '## Plan'
}

@test "the toolkit floor is 2.46.0" {
  grep -qF '">=2.46.0 <3"' "$ROOT/.claude-plugin/plugin.json"
}
