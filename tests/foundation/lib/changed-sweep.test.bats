#!/usr/bin/env bats
# A test that walks a source tree is a sweep: it carries '# changed: sweep <dir>...' naming each
# directory it walks, and `scripts/test-foundation.sh changed` runs it for a change under one of
# them. Walking means a glob over the directory, a find or a for loop in it, an agent or a skill
# reached through a variable (agents/kotlin-$a.md, skills/$v), or the whole directory handed to a
# tool ("$ROOT/skills" to ls, grep -r, cp -R): no file names its target literally, so nothing but
# the mark selects it. The per-file check is sweep_findings in helpers/sweep-lint.bash.

load "$(dirname "$BATS_TEST_FILENAME")/../helpers/sweep-lint"

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
}

# A fixture test file: <mark line or empty> followed by one line that walks skills/ and, with
# <more>, one that walks agents/.
fixture() {   # <name> <mark> [walk-agents]
  local f="$BATS_TEST_TMPDIR/$1.test.bats"
  { echo '#!/usr/bin/env bats'
    [ -z "$2" ] || echo "$2"
    echo 'for s in "$ROOT"/skills/*; do :; done'
    [ -z "${3:-}" ] || echo 'x="$ROOT/agents/kotlin-$a.md"'
  } >"$f"
  printf '%s\n' "$f"
}

@test "every test that walks a source tree names the directories it walks in its mark" {
  bad=""
  for f in "$ROOT"/tests/foundation/lib/*.bats; do
    [ "$(basename "$f")" = changed-sweep.test.bats ] && continue
    out="$(sweep_findings "$f")"
    [ -z "$out" ] || bad="$bad"$'\n'"$(basename "$f"): $(tr '\n' ';' <<<"$out")"
  done
  [ -z "$bad" ] || { echo "sweep marks to fix:$bad"; return 1; }
}

@test "a right mark and a file that walks nothing are clean" {
  [ -z "$(sweep_findings "$(fixture ok '# changed: sweep skills')")" ]
  [ -z "$(sweep_findings "$(fixture two '# changed: sweep skills agents' a)")" ]
  printf '#!/usr/bin/env bats\n# names scripts/a.sh\n' >"$BATS_TEST_TMPDIR/none.test.bats"
  [ -z "$(sweep_findings "$BATS_TEST_TMPDIR/none.test.bats")" ]
}

@test "a bare sweep mark is a finding" {
  run sweep_findings "$(fixture bare '# changed: sweep')"
  grep -qF -- "bare sweep mark" <<<"$output"
  run sweep_findings "$(fixture bare-two '# changed: sweep' a)"
  grep -qF -- "bare sweep mark" <<<"$output"
  grep -qF -- "walks skills but" <<<"$output"
  grep -qF -- "walks agents but" <<<"$output"
}

@test "a walk with no mark is a finding" {
  run sweep_findings "$(fixture unmarked '')"
  [ "$output" = "walks skills but the mark does not name it" ]
}

@test "a walked directory missing from the mark is a finding" {
  run sweep_findings "$(fixture missing '# changed: sweep skills' a)"
  [ "$output" = "walks agents but the mark does not name it" ]
}

@test "a directory in the mark the file never walks is a finding" {
  run sweep_findings "$(fixture extra '# changed: sweep skills commands')"
  [ "$output" = "the mark names commands, which the file never walks" ]
}

@test "a tab in the mark is a finding, though the words are right" {
  run sweep_findings "$(fixture tabbed $'# changed: sweep skills\tagents' a)"
  [ "$output" = "the mark has a tab: separate the directories with spaces" ]
}

@test "an unknown word in the mark is a finding" {
  run sweep_findings "$(fixture unknown '# changed: sweep skills workflows')"
  grep -qF -- "unknown word 'workflows'" <<<"$output"
}

@test "a mark on a file that walks nothing is a finding" {
  printf '#!/usr/bin/env bats\n# changed: sweep skills\n# names scripts/a.sh\n' >"$BATS_TEST_TMPDIR/none.test.bats"
  run sweep_findings "$BATS_TEST_TMPDIR/none.test.bats"
  [ "$output" = "the mark names skills, which the file never walks" ]
}

@test "an agent reached through a variable counts as agents, a skill through a variable as skills" {
  printf 'x="$ROOT/agents/kotlin-$a.md"\n' >"$BATS_TEST_TMPDIR/a.test.bats"
  [ "$(sweep_walked "$BATS_TEST_TMPDIR/a.test.bats")" = agents ]
  printf 'x="$ROOT/skills/$v/SKILL.md"\n' >"$BATS_TEST_TMPDIR/s.test.bats"
  [ "$(sweep_walked "$BATS_TEST_TMPDIR/s.test.bats")" = skills ]
}

@test "a recursive scan of the repository root walks every directory" {
  printf 'x="$(grep -rl foo "$ROOT" --exclude-dir=.git)"\n' >"$BATS_TEST_TMPDIR/g.test.bats"
  [ "$(sweep_walked "$BATS_TEST_TMPDIR/g.test.bats" | tr '\n' ' ')" = "$SWEEP_DIRS " ]
  printf 'x="$(grep -rn --exclude-dir=.git \\\n  -e . "${ROOT}" | wc -l)"\n' >"$BATS_TEST_TMPDIR/g2.test.bats"
  [ "$(sweep_walked "$BATS_TEST_TMPDIR/g2.test.bats" | tr '\n' ' ')" = "$SWEEP_DIRS " ]
  printf 'x="$(find "$ROOT" -name "*.md")"\n' >"$BATS_TEST_TMPDIR/g3.test.bats"
  [ "$(sweep_walked "$BATS_TEST_TMPDIR/g3.test.bats" | tr '\n' ' ')" = "$SWEEP_DIRS " ]
}

@test "git grep over the repository walks every directory" {
  printf 'x="$(git -C "$ROOT" grep -l foo)"\n' >"$BATS_TEST_TMPDIR/gg.test.bats"
  [ "$(sweep_walked "$BATS_TEST_TMPDIR/gg.test.bats" | tr '\n' ' ')" = "$SWEEP_DIRS " ]
}

@test "a scan of one directory under the root does not walk the others" {
  printf 'x="$(grep -rl foo "$ROOT/agents")"\nfind "$ROOT/scripts" -type f\n' >"$BATS_TEST_TMPDIR/one.test.bats"
  [ "$(sweep_walked "$BATS_TEST_TMPDIR/one.test.bats")" = agents ]
}

@test "a recursive grep handed bare directory words walks each of them, over continued lines too" {
  printf "hits=\"\$(cd \"\$ROOT\" && grep -rniE 'a|b' \\\\\n    skills agents README.md)\"\n" >"$BATS_TEST_TMPDIR/bare.test.bats"
  [ "$(sweep_walked "$BATS_TEST_TMPDIR/bare.test.bats" | tr '\n' ' ')" = "skills agents " ]
  printf 'echo skills agents\n' >"$BATS_TEST_TMPDIR/echo.test.bats"
  [ -z "$(sweep_walked "$BATS_TEST_TMPDIR/echo.test.bats")" ]
}

@test "a glob inside a directory path walks that directory" {
  printf 'files=("$ROOT"/agents/kotlin-*.x)\n' >"$BATS_TEST_TMPDIR/glob.test.bats"
  [ "$(sweep_walked "$BATS_TEST_TMPDIR/glob.test.bats")" = agents ]
  printf 'files=("$ROOT"/commands/*/locales/*.md)\n' >"$BATS_TEST_TMPDIR/glob2.test.bats"
  [ "$(sweep_walked "$BATS_TEST_TMPDIR/glob2.test.bats")" = commands ]
}

@test "a whole-root scan closed by a parenthesis walks every directory" {
  printf 'x=$(grep -rl foo "$ROOT")\n' >"$BATS_TEST_TMPDIR/paren.test.bats"
  [ "$(sweep_walked "$BATS_TEST_TMPDIR/paren.test.bats" | tr '\n' ' ')" = "$SWEEP_DIRS " ]
}

@test "a recursive flag outside the first flag cluster still makes a scan recursive" {
  for cmd in 'grep -n -r foo "$ROOT"' 'grep -R foo "$ROOT"' 'grep --include=*.md -r foo "$ROOT"' 'grep --recursive foo "$ROOT"'; do
    printf '%s\n' "x=\$($cmd)" >"$BATS_TEST_TMPDIR/late.test.bats"
    [ "$(sweep_walked "$BATS_TEST_TMPDIR/late.test.bats" | tr '\n' ' ')" = "$SWEEP_DIRS " ] || { echo "not recursive: $cmd"; return 1; }
  done
  printf 'grep -n foo "$ROOT"\n' >"$BATS_TEST_TMPDIR/flat.test.bats"
  [ -z "$(sweep_walked "$BATS_TEST_TMPDIR/flat.test.bats")" ]
}

@test "a comment that names a glob walks nothing" {
  printf '# globs workflows/wf_*.json and $ROOT/skills/*\nx=1\n' >"$BATS_TEST_TMPDIR/comment.test.bats"
  [ -z "$(sweep_walked "$BATS_TEST_TMPDIR/comment.test.bats")" ]
}

@test "a recursive scan of a subdirectory walks its directory" {
  printf 'x="$(grep -rlE foo "$ROOT/templates/task-md")"\n' >"$BATS_TEST_TMPDIR/sub.test.bats"
  [ "$(sweep_walked "$BATS_TEST_TMPDIR/sub.test.bats")" = templates ]
  printf 'find "$ROOT/skills/setup" -type f\n' >"$BATS_TEST_TMPDIR/subfind.test.bats"
  [ "$(sweep_walked "$BATS_TEST_TMPDIR/subfind.test.bats")" = skills ]
  printf 'grep -n foo "$ROOT/skills/setup/SKILL.md"\n' >"$BATS_TEST_TMPDIR/flatsub.test.bats"
  [ -z "$(sweep_walked "$BATS_TEST_TMPDIR/flatsub.test.bats")" ]
  printf 'grep -rn foo "$ROOT/skills/setup/SKILL.md"\n' >"$BATS_TEST_TMPDIR/file.test.bats"
  [ -z "$(sweep_walked "$BATS_TEST_TMPDIR/file.test.bats")" ]
}

@test "a variable deeper than the first level under a directory walks that directory" {
  printf 'f="$ROOT/templates/agents-md-stub/$l.md"\n' >"$BATS_TEST_TMPDIR/deep.test.bats"
  [ "$(sweep_walked "$BATS_TEST_TMPDIR/deep.test.bats")" = templates ]
  printf 'f="${ROOT}/templates/a/b/c-$x/x.md"\n' >"$BATS_TEST_TMPDIR/deeper.test.bats"
  [ "$(sweep_walked "$BATS_TEST_TMPDIR/deeper.test.bats")" = templates ]
  printf 'f="$ROOT/skills/a/b/SKILL.md"\n' >"$BATS_TEST_TMPDIR/literal.test.bats"
  [ -z "$(sweep_walked "$BATS_TEST_TMPDIR/literal.test.bats")" ]
}

@test "a variable under a named skill, or a scan of one, is not a walk of skills; a variable in place of the skill is" {
  printf 'f="$ROOT/skills/foo/locales/$l.md"\n' >"$BATS_TEST_TMPDIR/named.test.bats"
  [ -z "$(sweep_walked "$BATS_TEST_TMPDIR/named.test.bats")" ]
  printf 'f="${ROOT}/skills/foo/a/b/$l.md"\n' >"$BATS_TEST_TMPDIR/namedeep.test.bats"
  [ -z "$(sweep_walked "$BATS_TEST_TMPDIR/namedeep.test.bats")" ]
  printf 'x="$(grep -rqF foo "$ROOT/skills/foo")"\n' >"$BATS_TEST_TMPDIR/scan.test.bats"
  [ -z "$(sweep_walked "$BATS_TEST_TMPDIR/scan.test.bats")" ]
  printf 'f="$ROOT/skills/$s/locales/en.md"\n' >"$BATS_TEST_TMPDIR/var.test.bats"
  [ "$(sweep_walked "$BATS_TEST_TMPDIR/var.test.bats")" = skills ]
  printf 'f="$ROOT/skills/foo-$s/locales/en.md"\n' >"$BATS_TEST_TMPDIR/prefix.test.bats"
  [ "$(sweep_walked "$BATS_TEST_TMPDIR/prefix.test.bats")" = skills ]
}
