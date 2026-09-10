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
  grep -qE '^default[[:space:]]*=[[:space:]]*mobile-driver$' <<<"$block"
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

@test "the declared core floor is the one that reads a Driver block" {
  # `surfaces` is read by core from 1.7.1. A floor below it loads and is then
  # misread: core looks for a row this manifest means and never finds it.
  run python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["dependencies"]; print([x["version"] for x in d if x["name"]=="spine-toolkit"][0])' "$ROOT/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = ">=1.7.1 <2" ] || { echo "floor: $output"; return 1; }
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
