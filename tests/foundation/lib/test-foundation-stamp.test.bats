#!/usr/bin/env bats
# A green `test-foundation.sh all` records the tree it verified in `spine-verified-trees` under the
# repository's common git directory. Each test builds a small repository with a copy of the script
# and a fake `bats` first on PATH: it saves its arguments, runs $FAKE_BATS_SIDE if set and exits
# with ${FAKE_BATS_RC:-0}. The repository path holds a space, so unquoted paths show.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  R="$BATS_TEST_TMPDIR/my repo"
  S="$R/.git/spine-verified-trees"
  mkdir -p "$R/scripts" "$R/tests/foundation/lib" "$BATS_TEST_TMPDIR/bin"
  cp "$ROOT/scripts/test-foundation.sh" "$R/scripts/test-foundation.sh"
  printf '# names nothing\n' >"$R/tests/foundation/lib/a.test.bats"
  mkdir -p "$R/tests/fixtures/fixture-driver/.claude-plugin"
  echo '{}' >"$R/tests/fixtures/fixture-driver/.claude-plugin/plugin.json"
  printf '# tests/fixtures/fixture-driver/.claude-plugin/plugin.json\n' >"$R/tests/foundation/lib/driver.test.bats"
  printf '# .claude-plugin/plugin.json\n' >"$R/tests/foundation/lib/manifest.test.bats"
  printf '# names no path\n' >"$R/tests/foundation/lib/other.test.bats"
  printf '# reads ${SPINE_TOOLKIT_CORE:-$ROOT/../spine-toolkit}\n' >"$R/tests/foundation/lib/toolkit.test.bats"
  cat >"$BATS_TEST_TMPDIR/bin/bats" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/bats-args"
if [ -n "${FAKE_BATS_SIDE:-}" ]; then eval "$FAKE_BATS_SIDE"; fi
exit "${FAKE_BATS_RC:-0}"
FAKE
  chmod +x "$BATS_TEST_TMPDIR/bin/bats"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  git -C "$R" init -q -b main
  git -C "$R" add -A
  git -C "$R" -c user.name=t -c user.email=t@t commit -qm base
}

@test "a green all records the tree it ran on" {
  run "$R/scripts/test-foundation.sh" all
  [ "$status" -eq 0 ]
  [ "$(tail -1 "$S")" = "$(git -C "$R" rev-parse 'HEAD^{tree}')" ]
}

@test "a red all records nothing and keeps the bats exit code" {
  FAKE_BATS_RC=3 run "$R/scripts/test-foundation.sh" all
  [ "$status" -eq 3 ]
  [ ! -e "$S" ]
}

@test "a dirty tree is recorded as the tree its commit will have" {
  echo more >>"$R/tests/foundation/lib/a.test.bats"
  echo new >"$R/untracked.txt"
  run "$R/scripts/test-foundation.sh" all
  git -C "$R" add -A
  git -C "$R" -c user.name=t -c user.email=t@t commit -qm c
  [ "$(tail -1 "$S")" = "$(git -C "$R" rev-parse 'HEAD^{tree}')" ]
}

@test "the real index is left as it was" {
  echo new >"$R/untracked.txt"
  before="$(git -C "$R" status --porcelain)"
  run "$R/scripts/test-foundation.sh" all
  [ "$(git -C "$R" status --porcelain)" = "$before" ]
}

@test "a run in a worktree records in the main repository's .git" {
  git -C "$R" worktree add -q "$BATS_TEST_TMPDIR/wt" -b side
  run "$BATS_TEST_TMPDIR/wt/scripts/test-foundation.sh" all
  [ "$(tail -1 "$S")" = "$(git -C "$BATS_TEST_TMPDIR/wt" rev-parse 'HEAD^{tree}')" ]
}

@test "a tree that changed during the run is not recorded" {
  FAKE_BATS_SIDE="echo x >'$R/late.txt'" run "$R/scripts/test-foundation.sh" all
  [ "$status" -eq 0 ]
  [ ! -e "$S" ]
}

@test "unit and changed record nothing" {
  run "$R/scripts/test-foundation.sh" unit
  TEST_BASE=main run "$R/scripts/test-foundation.sh" changed
  [ ! -e "$S" ]
}

@test "snippets records nothing" {
  run "$R/scripts/test-foundation.sh" snippets
  [ "$status" -eq 0 ]
  [ ! -e "$S" ]
}

@test "the stamp keeps the last 20 trees" {
  for i in $(seq 1 22); do
    echo "$i" >"$R/n.txt"
    "$R/scripts/test-foundation.sh" all
  done
  [ "$(wc -l <"$S" | tr -d ' ')" -eq 20 ]
  [ "$(sort -u "$S" | wc -l | tr -d ' ')" -eq 20 ]
}

@test "a script outside the repository root records nothing" {
  O="$BATS_TEST_TMPDIR/outer"
  git init -q "$O"
  cp -R "$R" "$O/plugin"
  rm -rf "$O/plugin/.git"
  run "$O/plugin/scripts/test-foundation.sh" all
  [ "$status" -eq 0 ]
  [ ! -e "$O/.git/spine-verified-trees" ]
}

@test "a stamp that cannot be written leaves the exit code and says so" {
  mkdir "$S"
  run --separate-stderr "$R/scripts/test-foundation.sh" all
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"test-foundation: could not record the verified tree"* ]]
}

@test "touched runs the tests that name the files, not the whole lib for a fixture" {
  run --separate-stderr "$R/scripts/test-foundation.sh" touched tests/fixtures/fixture-driver/.claude-plugin/plugin.json
  [ "$status" -eq 0 ]
  # the manifest test holds the shorter path only, so it is not chosen; other and lib/ are not either;
  # the test that reads the toolkit checkout is always there
  [ "$(cat "$BATS_TEST_TMPDIR/bats-args")" = "$R/tests/foundation/lib/driver.test.bats"$'\n'"$R/tests/foundation/lib/toolkit.test.bats" ]
  [[ "$stderr" == *"touched: tests/fixtures/fixture-driver/.claude-plugin/plugin.json -> "* ]]
}

@test "touched with a shorter path also runs the tests that hold the longer one" {
  run --separate-stderr "$R/scripts/test-foundation.sh" touched .claude-plugin/plugin.json
  [ "$status" -eq 0 ]
  [ "$(grep -c . "$BATS_TEST_TMPDIR/bats-args")" -eq 3 ]
  [ "$(grep -c 'driver.test.bats' "$BATS_TEST_TMPDIR/bats-args")" -eq 1 ]
  [ "$(grep -c 'manifest.test.bats' "$BATS_TEST_TMPDIR/bats-args")" -eq 1 ]
}

@test "touched with several files runs each test once" {
  run --separate-stderr "$R/scripts/test-foundation.sh" touched tests/fixtures/fixture-driver/.claude-plugin/plugin.json .claude-plugin/plugin.json
  [ "$status" -eq 0 ]
  [ "$(grep -c . "$BATS_TEST_TMPDIR/bats-args")" -eq 3 ]
  [ "$(grep -c 'driver.test.bats' "$BATS_TEST_TMPDIR/bats-args")" -eq 1 ]
  [ "$(grep -c 'manifest.test.bats' "$BATS_TEST_TMPDIR/bats-args")" -eq 1 ]
  [ "$(grep -c 'toolkit.test.bats' "$BATS_TEST_TMPDIR/bats-args")" -eq 1 ]
}

@test "touched on a file no test names still runs the tests that read the toolkit checkout" {
  run --separate-stderr "$R/scripts/test-foundation.sh" touched docs/nothing.md
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/bats-args")" = "$R/tests/foundation/lib/toolkit.test.bats" ]
  [[ "$stderr" == *"touched: docs/nothing.md -> no test names it"* ]]
  [[ "$stderr" == *"touched: tests that read the spine-toolkit checkout -> toolkit.test.bats"* ]]
  [[ "$stderr" != *"touched: no test names these files"* ]]
}

@test "touched on files no test names, with no test reading the toolkit, runs nothing and passes" {
  rm "$R/tests/foundation/lib/toolkit.test.bats"
  run --separate-stderr "$R/scripts/test-foundation.sh" touched docs/nothing.md
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/bats-args" ]
  [[ "$stderr" == *"touched: docs/nothing.md -> no test names it"* ]]
  [[ "$stderr" == *"touched: no test names these files"* ]]
  [[ "$stderr" != *"tests that read the spine-toolkit checkout"* ]]
}

@test "touched without files is a usage error" {
  run --separate-stderr "$R/scripts/test-foundation.sh" touched
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"usage:"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/bats-args" ]
}

@test "touched keeps the bats exit code and records nothing" {
  FAKE_BATS_RC=1 run "$R/scripts/test-foundation.sh" touched .claude-plugin/plugin.json
  [ "$status" -eq 1 ]
  [ ! -e "$S" ]
  run "$R/scripts/test-foundation.sh" touched .claude-plugin/plugin.json
  [ "$status" -eq 0 ]
  [ ! -e "$S" ]
}
