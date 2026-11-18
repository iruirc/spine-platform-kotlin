#!/usr/bin/env bats
# `test-foundation.sh changed` picks the test files that name what a branch touched. Each test
# builds a small repository, changes one thing on a branch and reads the selection from
# `changed --list`; the script copied into the repository resolves its root there. The repository
# path holds a space, so a summary that splits paths on spaces shows. The spine-toolkit checkout
# beside the plugin is an empty directory unless a test says otherwise.

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
  printf '# names skills/arch-mvvm/\n' >"$lib/mvvm.test.bats"
  printf '# names skills/arch-mvvm-x\n' >"$lib/mvvm-x.test.bats"
  printf '#!/usr/bin/env bats\n# changed: sweep\n' >"$lib/sweep.test.bats"
  printf '# names nothing\n' >"$lib/other.test.bats"
  printf '# names scripts/a.sh\n' >"$lib/with space.test.bats"
  git -C "$R" init -q -b main
  git -C "$R" add -A
  git -C "$R" -c user.name=t -c user.email=t@t commit -qm base
  git -C "$R" checkout -q -b work
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

@test "a skill file selects its skill's tests and the sweeps" {
  echo more >>"$R/skills/arch-mvvm/SKILL.md"
  changed
  [ "$status" -eq 0 ]
  [ "$(names)" = $'mvvm.test.bats\nsweep.test.bats' ]
}

@test "an agent file selects the sweeps" {
  echo more >>"$R/agents/kotlin-reviewer.md"
  changed
  [ "$status" -eq 0 ]
  [ "$(names)" = "sweep.test.bats" ]
}

@test "a conventions file selects the sweeps" {
  echo more >>"$R/conventions/layout.md"
  changed
  [ "$status" -eq 0 ]
  [ "$(names)" = "sweep.test.bats" ]
}

@test "a command file selects the sweeps" {
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

@test "an untracked file under skills selects the sweeps" {
  mkdir -p "$R/skills/new"
  echo n >"$R/skills/new/SKILL.md"
  changed
  [ "$status" -eq 0 ]
  [ "$(names)" = "sweep.test.bats" ]
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
