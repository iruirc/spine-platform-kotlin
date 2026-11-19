#!/usr/bin/env bats
# `test-foundation.sh changed` picks the test files that name what a branch touched. Each test
# builds a small repository, changes one thing on a branch and reads the selection from
# `changed --list`; the script copied into the repository resolves its root there. The repository
# path holds a space, so a summary that splits paths on spaces shows. The spine-toolkit checkout
# beside the plugin is an empty directory unless a test says otherwise. `touched` has no `--list`, so
# a stub `bats` first on PATH prints its arguments one per line and the selection is its output.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  R="$BATS_TEST_TMPDIR/my repo"
  mkdir -p "$BATS_TEST_TMPDIR/empty-core"
  export SPINE_TOOLKIT_CORE="$BATS_TEST_TMPDIR/empty-core"
  mkdir -p "$R/scripts" "$R/tests/foundation/helpers" "$R/tests/foundation/fixtures" \
           "$R/tests/foundation/lib" "$R/tests/foundation/snippets"
  mkdir -p "$R/skills/arch-mvvm" "$R/skills/arch-mvvm-x" "$R/agents" "$R/conventions" "$R/commands"
  cp "$ROOT/scripts/test-foundation.sh" "$R/scripts/test-foundation.sh"
  echo a >"$R/scripts/a.sh"
  echo o >"$R/scripts/orphan.sh"
  echo c >"$R/scripts/café.sh"
  echo s >"$R/skills/arch-mvvm/SKILL.md"
  echo s >"$R/skills/arch-mvvm-x/SKILL.md"
  echo g >"$R/agents/kotlin-reviewer.md"
  echo v >"$R/conventions/layout.md"
  echo m >"$R/commands/setup.md"
  echo h >"$R/tests/foundation/helpers/h.bash"
  echo f >"$R/tests/foundation/fixtures/f.txt"
  echo k >"$R/tests/foundation/snippets/build.gradle.kts"
  local lib="$R/tests/foundation/lib"
  printf '# names scripts/a.sh and scripts/café.sh\n' >"$lib/a.test.bats"
  printf '# names skills/arch-mvvm/ and skills/arch-mvvm/SKILL.md\n' >"$lib/mvvm.test.bats"
  printf '# names skills/arch-mvvm-x\n' >"$lib/mvvm-x.test.bats"
  printf '#!/usr/bin/env bats\n# changed: sweep agents commands\n' >"$lib/sweep.test.bats"
  printf '#!/usr/bin/env bats\n# changed: sweep skills conventions\n' >"$lib/sweep-skills.test.bats"
  printf '# names nothing\n' >"$lib/other.test.bats"
  printf '# names scripts/a.sh\n' >"$lib/with space.test.bats"
  git -C "$R" init -q -b main
  git -C "$R" add -A
  git -C "$R" -c user.name=t -c user.email=t@t commit -qm base
  git -C "$R" checkout -q -b work
  mkdir -p "$BATS_TEST_TMPDIR/stub"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' >"$BATS_TEST_TMPDIR/stub/bats"
  chmod +x "$BATS_TEST_TMPDIR/stub/bats"
  PATH="$BATS_TEST_TMPDIR/stub:$PATH"
}

commit() {
  git -C "$R" add -A
  git -C "$R" -c user.name=t -c user.email=t@t commit -qm "$1"
}

# Runs the copy of the script in the repository; stdout is $output, stderr is $stderr_text.
changed() {
  run --separate-stderr "$R/scripts/test-foundation.sh" changed --list
  stderr_text="${stderr:-}"
}

# Runs `touched` with the stub bats; the selection is $output, stderr is $stderr_text.
touched() {
  run --separate-stderr "$R/scripts/test-foundation.sh" touched "$@"
  stderr_text="${stderr:-}"
}

# The selection as file names, one per line, directories left whole.
names() {
  printf '%s\n' "$output" | sed '/^$/d' | while IFS= read -r p; do
    case "$p" in */tests/foundation/lib) echo "DIR" ;; *) basename "$p" ;; esac
  done
}

@test "a script selects the tests that name it" {
  echo more >>"$R/scripts/a.sh"
  changed
  [ "$status" -eq 0 ]
  [ "$(names)" = $'a.test.bats\nwith space.test.bats' ]
}

@test "a skill file selects its skill's tests and the skills sweep, not the agents sweep" {
  echo more >>"$R/skills/arch-mvvm/SKILL.md"
  changed
  [ "$status" -eq 0 ]
  [ "$(names)" = $'mvvm.test.bats\nsweep-skills.test.bats' ]
}

@test "an agent file selects the agents sweep only" {
  echo more >>"$R/agents/kotlin-reviewer.md"
  changed
  [ "$status" -eq 0 ]
  [ "$(names)" = "sweep.test.bats" ]
}

@test "a change in a directory no sweep names selects no sweep" {
  mkdir -p "$R/templates"
  echo t >"$R/templates/task.md"
  changed
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qF -- "templates/task.md -> no test names it" <<<"$stderr_text"
}

@test "a conventions file selects the skills sweep, whose mark names it" {
  echo more >>"$R/conventions/layout.md"
  changed
  [ "$status" -eq 0 ]
  [ "$(names)" = "sweep-skills.test.bats" ]
}

@test "a command file selects the sweep whose mark names commands" {
  echo more >>"$R/commands/setup.md"
  changed
  [ "$status" -eq 0 ]
  [ "$(names)" = "sweep.test.bats" ]
}

@test "a renamed script still selects the tests that name the old path" {
  git -C "$R" mv scripts/a.sh scripts/b.sh
  commit rename
  changed
  [ "$status" -eq 0 ]
  [ "$(names)" = $'a.test.bats\nwith space.test.bats' ]
}

@test "an untracked file under skills selects the skills sweep" {
  mkdir -p "$R/skills/new"
  echo n >"$R/skills/new/SKILL.md"
  changed
  [ "$status" -eq 0 ]
  [ "$(names)" = "sweep-skills.test.bats" ]
}

@test "a path with a non-ASCII name selects the test that names it" {
  echo more >>"$R/scripts/café.sh"
  changed
  [ "$status" -eq 0 ]
  [ "$(names)" = "a.test.bats" ]
  [[ "$stderr_text" == *"scripts/café.sh -> a.test.bats"* ]]
}

@test "the stderr summary keeps a path with a space whole" {
  echo more >>"$R/scripts/a.sh"
  changed
  [ "$status" -eq 0 ]
  [[ "$stderr_text" == *"scripts/a.sh -> a.test.bats with space.test.bats"* ]]
}

@test "a changed test file selects itself" {
  echo more >>"$R/tests/foundation/lib/other.test.bats"
  changed
  [ "$status" -eq 0 ]
  [ "$(names)" = "other.test.bats" ]
}

@test "a removed test file runs nothing and says so" {
  git -C "$R" rm -q tests/foundation/lib/other.test.bats
  commit remove
  changed
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr_text" == *"tests/foundation/lib/other.test.bats -> removed, nothing to run"* ]]
}

@test "a helper change selects the whole suite" {
  echo more >>"$R/tests/foundation/helpers/h.bash"
  changed
  [ "$status" -eq 0 ]
  [ "$(names)" = "DIR" ]
}

@test "a fixture change selects the whole suite" {
  echo more >>"$R/tests/foundation/fixtures/f.txt"
  changed
  [ "$status" -eq 0 ]
  [ "$(names)" = "DIR" ]
}

@test "a change under the snippets project never selects it" {
  echo more >>"$R/tests/foundation/snippets/build.gradle.kts"
  changed
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr_text" == *"tests/foundation/snippets/build.gradle.kts -> no test names it"* ]]
}

@test "a file no test names is reported, not run" {
  echo more >>"$R/scripts/orphan.sh"
  changed
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr_text" == *"scripts/orphan.sh -> no test names it"* ]]
}

@test "nothing changed selects nothing" {
  changed
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr_text" == *"nothing differs"* ]]
}

@test "no merge base exits 2 and names TEST_BASE" {
  echo more >>"$R/scripts/a.sh"
  TEST_BASE=nope changed
  [ "$status" -eq 2 ]
  [[ "$stderr_text" == *"TEST_BASE"* ]]
}

@test "a change in the toolkit beside selects unit" {
  C="$BATS_TEST_TMPDIR/core"
  mkdir -p "$C"
  echo c >"$C/file"
  git -C "$C" init -q -b main
  git -C "$C" add -A
  git -C "$C" -c user.name=t -c user.email=t@t commit -qm base
  git -C "$C" checkout -q -b work
  echo more >>"$C/file"
  SPINE_TOOLKIT_CORE="$C" changed
  [ "$status" -eq 0 ]
  [ "$(names)" = "DIR" ]
  [[ "$stderr_text" == *"1 file(s) in the toolkit beside"* ]]
}

@test "a toolkit beside that is not a git checkout is ignored" {
  echo more >>"$R/scripts/a.sh"
  changed
  [ "$status" -eq 0 ]
  [ "$(names)" = $'a.test.bats\nwith space.test.bats' ]
}

@test "touched with no arguments selects the tests that name a modified file" {
  echo more >>"$R/scripts/a.sh"
  touched
  [ "$status" -eq 0 ]
  [ "$(names)" = $'a.test.bats\nwith space.test.bats' ]
}

@test "a staged-only file is selected" {
  echo x >>"$R/scripts/a.sh"
  git -C "$R" add scripts/a.sh
  touched
  [ "$status" -eq 0 ]
  [ "$(names)" = $'a.test.bats\nwith space.test.bats' ]
}

@test "a file both staged and modified again is listed once" {
  echo x >>"$R/scripts/orphan.sh"
  git -C "$R" add scripts/orphan.sh
  echo y >>"$R/scripts/orphan.sh"
  touched
  [ "$status" -eq 0 ]
  [ "$(grep -c 'scripts/orphan.sh -> ' <<<"$stderr_text")" -eq 1 ]
}

@test "an untracked file is selected" {
  echo n >"$R/scripts/new.sh"
  printf '# names scripts/new.sh\n' >"$R/tests/foundation/lib/new.test.bats"
  touched
  [ "$status" -eq 0 ]
  grep -qF -- "new.test.bats" <<<"$(names)"
  grep -qF -- "scripts/new.sh -> new.test.bats" <<<"$stderr_text"
}

@test "a non-ASCII path from the worktree is selected" {
  echo more >>"$R/scripts/café.sh"
  touched
  [ "$status" -eq 0 ]
  [ "$(names)" = "a.test.bats" ]
}

@test "nothing to commit runs nothing" {
  touched
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qF -- "touched: nothing differs from HEAD" <<<"$stderr_text"
}

@test "touched with no arguments: a changed test file selects itself" {
  echo more >>"$R/tests/foundation/lib/other.test.bats"
  touched
  [ "$status" -eq 0 ]
  [ "$(names)" = "other.test.bats" ]
}

@test "touched with the path as an argument: a changed test file selects itself" {
  touched tests/foundation/lib/other.test.bats
  [ "$status" -eq 0 ]
  [ "$(names)" = "other.test.bats" ]
}

@test "touched with no arguments: a removed test file runs nothing and says so" {
  git -C "$R" rm -q tests/foundation/lib/other.test.bats
  touched
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qF -- "tests/foundation/lib/other.test.bats -> removed, nothing to run" <<<"$stderr_text"
}

@test "touched with the path as an argument: a removed test file runs nothing and says so" {
  git -C "$R" rm -q tests/foundation/lib/other.test.bats
  touched tests/foundation/lib/other.test.bats
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qF -- "tests/foundation/lib/other.test.bats -> removed, nothing to run" <<<"$stderr_text"
}

@test "touched: a helper change selects the tests that load it" {
  local lib="$R/tests/foundation/lib"
  printf "load '../helpers/h'\n" >"$lib/uses-h.test.bats"
  commit "a test that loads h"
  echo more >>"$R/tests/foundation/helpers/h.bash"
  touched
  [ "$status" -eq 0 ]
  [ "$(names)" = "uses-h.test.bats" ]
  grep -qF -- "touched: tests/foundation/helpers/h.bash -> uses-h.test.bats" <<<"$stderr_text"
}

@test "touched: a helper loaded through another helper selects that helper's tests" {
  local lib="$R/tests/foundation/lib" hd="$R/tests/foundation/helpers"
  printf 'load "$BATS_TEST_DIRNAME/../helpers/h"\n' >"$hd/outer.bash"
  printf 'source "$ROOT/tests/foundation/helpers/outer.bash"\n' >"$hd/outer2.bash"
  printf "load '../helpers/h'\n" >"$lib/uses-h.test.bats"
  printf "load '../helpers/outer'\n" >"$lib/uses-outer.test.bats"
  printf "load '../helpers/outer2'\n" >"$lib/uses-outer2.test.bats"
  echo z >"$hd/zzz.bash"
  printf "load '../helpers/zzz'\n" >"$lib/uses-zzz.test.bats"
  commit "helpers and the tests that load them"
  echo more >>"$hd/h.bash"
  touched
  [ "$status" -eq 0 ]
  [ "$(names)" = "uses-h.test.bats
uses-outer.test.bats
uses-outer2.test.bats" ]
  # a test that loads an unrelated helper is not picked by the chain
  [ "$(grep -c 'uses-zzz' <<<"$output")" -eq 0 ]
}

@test "touched: helpers that load each other in a cycle still end" {
  local lib="$R/tests/foundation/lib" hd="$R/tests/foundation/helpers"
  printf 'load "../helpers/h"\n' >"$hd/outer.bash"
  printf 'load "../helpers/outer"\n' >"$hd/h.bash"
  printf "load '../helpers/outer'\n" >"$lib/uses-outer.test.bats"
  commit "helpers that load each other"
  echo more >>"$hd/h.bash"
  touched
  [ "$status" -eq 0 ]
  [ "$(names)" = "uses-outer.test.bats" ]
}

@test "touched: a helper no test loads runs nothing and says so" {
  echo more >>"$R/tests/foundation/helpers/h.bash"
  touched
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qF -- "touched: tests/foundation/helpers/h.bash -> no test loads it" <<<"$stderr_text"
}

@test "touched: a helper change given as an argument selects the tests that load it" {
  printf "load '../helpers/h'\n" >"$R/tests/foundation/lib/uses-h.test.bats"
  commit "a test that loads h"
  touched tests/foundation/helpers/h.bash
  [ "$status" -eq 0 ]
  [ "$(names)" = "uses-h.test.bats" ]
}

@test "touched: a fixture change selects the whole suite and no per-file pick" {
  echo more >>"$R/tests/foundation/fixtures/f.txt"
  echo more >>"$R/scripts/a.sh"
  touched
  [ "$status" -eq 0 ]
  [ "$(names)" = "DIR" ]
}

@test "explicit files keep their meaning" {
  echo more >>"$R/scripts/a.sh"
  commit change
  touched scripts/orphan.sh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -qF -- "touched: no test names these files" <<<"$stderr_text"
}

@test "a sweep is not selected by touched" {
  echo more >>"$R/skills/arch-mvvm/SKILL.md"
  touched
  [ "$status" -eq 0 ]
  [ "$(names)" = "mvvm.test.bats" ]
}

@test "touched with no arguments still adds the tests that read the toolkit checkout" {
  printf '# reads SPINE_TOOLKIT_CORE\n' >"$R/tests/foundation/lib/toolkit.test.bats"
  git -C "$R" add -A
  git -C "$R" -c user.name=t -c user.email=t@t commit -qm core-test
  echo more >>"$R/scripts/a.sh"
  touched
  [ "$status" -eq 0 ]
  [ "$(names)" = $'a.test.bats\ntoolkit.test.bats\nwith space.test.bats' ]
  grep -qF -- "touched: tests that read the spine-toolkit checkout -> toolkit.test.bats" <<<"$stderr_text"
}
