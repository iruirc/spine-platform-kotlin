#!/usr/bin/env bats
# changed: sweep agents
# A session can run a core older than this platform's agents need: the agents load from the newest
# install, the core from whatever the session started with. An agent that meets a core script or
# flag that is not there stops its stage — it never does the script's work by hand, and never runs
# a copy from another folder. The rule lives in the agent body because the core's conventions are
# read from that same old core.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  CORE="${SPINE_TOOLKIT_CORE:-$ROOT/../spine-toolkit}"
  GUARD='**A core script or flag that is not there.** When a `spine-toolkit` script these instructions name is missing under the core root, or rejects as unknown an option or value these instructions pass it (a usage error, not a finding), the session runs an older core than this platform needs. A script that exits non-zero to report findings, or a stop it is meant to give, is working: handle that exit as these instructions say. Do not do the work of a missing script by hand, and do not run it from any other folder — a neighbouring version in the plugin cache included. Stop the stage with the status that stops the run — `FAILED` from a validator, `DISCUSSION` from a reviewer — and open your summary and the Summary section of your artifact with: `core older than the platform needs: <script or flag> is missing in <core root>; restart the session`.'
}

@test "every agent that runs a core script carries the guard" {
  [ -d "$CORE/.git" ] || skip "no spine-toolkit checkout beside this one"
  missing=""
  for agent in "$ROOT"/agents/*.md; do
    # long-run.sh is in every core this platform's floor admits.
    scripts="$(grep -oE '[A-Za-z0-9_-]+\.sh' "$agent" | sort -u | while read -r s; do
      [ "$s" != long-run.sh ] && [ -f "$CORE/scripts/$s" ] && echo "$s"; done | tr '\n' ' ')"
    [ -z "$scripts" ] && continue
    grep -qxF "$GUARD" "$agent" || missing="$missing$(basename "$agent") ($scripts)\n"
  done
  [ -z "$missing" ] || { printf 'no guard paragraph in:\n%b' "$missing"; return 1; }
}

@test "the spine-toolkit range in plugin.json is one the core reads" {
  range="$(python3 -c 'import json,sys; print([d["version"] for d in json.load(open(sys.argv[1]))["dependencies"] if d["name"]=="spine-toolkit"][0])' "$ROOT/.claude-plugin/plugin.json")"
  if [ -f "$CORE/scripts/lib/core_compat.py" ]; then
    # Core's own parser: None is a range it cannot read, and a run would then never be checked.
    python3 -c 'import sys; sys.dont_write_bytecode = True; sys.path.insert(0, sys.argv[1]); from core_compat import in_range; sys.exit(in_range("0.0.0", sys.argv[2]) is None)' \
      "$CORE/scripts/lib" "$range" || { echo "core cannot read the range '$range'"; return 1; }
  else
    # No checkout beside: the grammar of core's scripts/lib/core_compat.py, comparisons separated by spaces.
    grep -qE '^(>=|<=|>|<|=)[0-9]+(\.[0-9]+){0,2}( (>=|<=|>|<|=)[0-9]+(\.[0-9]+){0,2})*$' <<<"$range" \
      || { echo "core cannot read the range '$range'"; return 1; }
  fi
}
