#!/usr/bin/env bats
# The platform half of core's driver contract: what this manifest declares to a
# driver, and the guarantee that no file here decides for the project which MCP
# server drives its app.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  M="$ROOT/skills/manifest/SKILL.md"
}

@test "the manifest declares a Driver block with both rows" {
  block="$(sed -n '/^## Driver$/,/^## /p' "$M")"
  grep -qE '^default[[:space:]]*=[[:space:]]*spine-driver-mobile$' <<<"$block"
  grep -qE '^surfaces[[:space:]]*=' <<<"$block"
}

@test "the declared surfaces are the two Android ones and the three desktop hosts" {
  # The vendored lint rejects a name outside core's eight; this pins which five of
  # the eight we mean. The server and CLI lanes produce none and appear in neither.
  block="$(sed -n '/^## Driver$/,/^## /p' "$M")"
  got="$(sed -n 's/^surfaces[[:space:]]*=[[:space:]]*//p' <<<"$block" | tr -d '[:space:]')"
  [ "$got" = "android-emulator,android-device,macos,windows,linux" ] \
    || { echo "surfaces: $got"; return 1; }
}

@test "the declared core floor reads everything this plugin relies on" {
  # `surfaces` is read by core from 1.7.1. A floor below it loads and is then
  # misread: core looks for a row this manifest means and never finds it. The agents no
  # longer pin opus, and the `## Models` a user sets to keep them on it exists from
  # 1.11.0.
  run python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["dependencies"]; print([x["version"] for x in d if x["name"]=="spine-toolkit"][0])' "$ROOT/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = ">=1.11.0 <2" ] || { echo "floor: $output"; return 1; }
}

@test "the vendored manifest lint is the copy that knows the Driver block" {
  # A pre-1.7.0 copy passes this manifest by never parsing the block at all — a
  # green run that checked nothing, which is worse than a red one.
  grep -q '^SURFACES=' "$ROOT/scripts/lint-manifest.sh"
}

@test "the vendored lint rejects a surface outside core's vocabulary" {
  # The negative control for the test above: proves the copy not only carries the
  # list but reaches it. Without this the guard is a grep for a variable name.
  tmp="$BATS_TEST_TMPDIR/plugin"
  mkdir -p "$tmp"
  cp -R "$ROOT/.claude-plugin" "$ROOT/agents" "$ROOT/skills" "$tmp/"
  sed 's/^surfaces[[:space:]]*=.*$/surfaces = android-emulator, pixel, macos/' "$M" \
    > "$tmp/skills/manifest/SKILL.md"
  run "$ROOT/scripts/lint-manifest.sh" "$tmp"
  [ "$status" -eq 1 ] || { echo "expected exit 1, got $status: $output"; return 1; }
  grep -q "surface outside core's vocabulary: pixel" <<<"$output" || { echo "$output"; return 1; }
}

@test "the UI validator glosses all four driver states" {
  V="$ROOT/agents/kotlin-ui-validator.md"
  bad=""
  for s in ok none unavailable incompatible; do
    grep -qF "\`$s\`" "$V" || bad="$bad $s"
  done
  [ -z "$bad" ] || { echo "states not glossed:$bad"; return 1; }
}

@test "the return contract carries driver_status with core's four values" {
  # core's profile scripts declare driver_status with exactly this enum under
  # additionalProperties:false, so a fifth value is a field the orchestrator drops.
  grep -qF 'driver_status: ok | none | unavailable | incompatible' \
    "$ROOT/agents/kotlin-ui-validator.md"
}

@test "no retired call name survives in the UI validator" {
  # The prefixed forms are caught by Task 7's tree-wide guard; `enable_module` is
  # the one bare name the old file used, and it would sail straight past it.
  V="$ROOT/agents/kotlin-ui-validator.md"
  grep -qF 'driver_status' "$V" || { echo "not the validator, or it lost driver_status"; return 1; }
  bad=""
  for c in enable_module app_launch input_tap screen_capture; do
    grep -qF "$c" "$V" && bad="$bad $c"
  done
  [ -z "$bad" ] || { echo "retired call names present:$bad"; return 1; }
}

@test "the UI validator names each lane's surface from core's vocabulary" {
  # The lane is what fixes the surface, and the surface is what the driver matches
  # on. A lane whose surface is unnamed cannot be matched against anything.
  V="$ROOT/agents/kotlin-ui-validator.md"
  bad=""
  for s in android-emulator android-device macos windows linux; do
    grep -qF "\`$s\`" "$V" || bad="$bad $s"
  done
  [ -z "$bad" ] || { echo "surfaces not named:$bad"; return 1; }
}

@test "no file in this plugin decides which MCP server drives the app" {
  # Which server drives is the project's choice from core 1.7.1 on. A name written
  # here is that choice made for them, wrong for every project that made another.
  # No --include: a YAML agent definition decides this as much as a Markdown one,
  # and enumerating types is how the first version of this guard missed files.
  # tests/ is excluded because this guard carries the very strings it forbids.
  scanned="$(grep -rl --exclude-dir=.git --exclude-dir=tests --exclude-dir=.superpowers \
               -e . "$ROOT" | wc -l | tr -d ' ')"
  [ "$scanned" -ge 60 ] || { echo "scan went vacuous: $scanned file(s)"; return 1; }
  offenders="$(grep -rliE 'mcp__mobile|mobile[ -]mcp' "$ROOT" \
                 --exclude-dir=.git --exclude-dir=tests --exclude-dir=.superpowers || true)"
  [ -z "$offenders" ] || { echo "$offenders"; return 1; }
}
