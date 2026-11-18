#!/usr/bin/env bash
# Adapted from spine-toolkit scripts/test-foundation.sh sha256:866794063f2fc3bd0102d547108f8140f3598822c3d31690bece69c9bee8f43a
# Adapted from spine-toolkit's test runner. Plugins share no code; update both or neither.
# Run Foundation bats tests.
# Usage: scripts/test-foundation.sh [unit|all|snippets|changed [--list]]
#   changed  runs the test files that name what the branch touched since its merge base with
#            $TEST_BASE (default main), or on main what is not pushed; uncommitted and untracked
#            files count. A change under skills/ agents/ conventions/ commands/ also runs the
#            sweeps, the tests marked '# changed: sweep' in their first 10 lines. A change to a
#            helper or a fixture, or in the spine-toolkit checkout beside this one, runs the whole
#            lib/ directory. A file no test names is reported on stderr and runs nothing. It never
#            selects tests/foundation/snippets: that is Gradle, run with `snippets`. --list prints
#            the selection, one path per line, instead of running it.
set -euo pipefail

target="${1:-all}"
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
lib="$root/tests/foundation/lib"

if ! command -v bats >/dev/null 2>&1; then
  echo "error: bats-core not on PATH. install: brew install bats-core" >&2
  exit 3
fi

# `all` differs from `unit` only when an integration suite exists; core has none
# today, and an `all` hard-coded to lib/ would silently not run one that appears.
suites=("$lib")
[ -d "$root/tests/foundation/integration" ] && suites+=("$root/tests/foundation/integration")

# Prints the files of <repo> that differ from <base> - committed since the merge base, uncommitted
# and untracked. On <base> itself the merge base is HEAD and would hide every local commit, so the
# comparison is with origin/<base>: what has not been pushed. A fresh clone of a branch has
# origin/<base> and no local <base>. Renames are listed as a delete and an add, so the old path of
# a renamed file still selects the tests that name it. quotePath is off so that a path with a
# non-ASCII name comes out as it is, not as an escaped string no test names.
diff_files() {   # <repo> <base>
  local repo="$1" base_ref="$2" base
  if [ "$(git -C "$repo" symbolic-ref --short -q HEAD || true)" = "$base_ref" ] ||
     ! git -C "$repo" rev-parse -q --verify "$base_ref^{commit}" >/dev/null; then
    base_ref="origin/$base_ref"
  fi
  base="$(git -C "$repo" merge-base HEAD "$base_ref")" || {
    echo "error: $repo has no merge base with '$base_ref'; set TEST_BASE" >&2; return 2; }
  { git -C "$repo" -c core.quotePath=false diff --name-only --no-renames "$base"
    git -C "$repo" -c core.quotePath=false ls-files --others --exclude-standard; } | sort -u
}

# Prints the bats arguments for the changed files, one per line, and why to stderr.
changed_suites() {
  local files core core_files f name picked all=0 selected="" sweeps="" where="here"
  files="$(diff_files "$root" "${TEST_BASE:-main}")" || exit 2
  # Tests under lib/ read the spine-toolkit checkout beside this one, so a change there can turn
  # them red with nothing changed here. A directory that is not a git checkout is ignored.
  core="${SPINE_TOOLKIT_CORE:-$root/../spine-toolkit}"
  if git -C "$core" rev-parse -q --git-dir >/dev/null 2>&1; then
    where="here or in the toolkit beside"
    core_files="$(diff_files "$core" main)" || exit 2
    if [ -n "$core_files" ]; then
      echo "changed: $(printf '%s\n' "$core_files" | wc -l | tr -d ' ') file(s) in the toolkit beside -> all of tests/foundation/lib" >&2
      all=1
    fi
  fi
  if [ -z "$files" ] && [ "$all" -eq 0 ]; then
    echo "changed: nothing differs from ${TEST_BASE:-main} $where" >&2
    return 0
  fi
  for f in "$lib"/*.bats; do
    if head -10 "$f" | grep -qx '# changed: sweep'; then sweeps="$sweeps"$'\n'"$f"; fi
  done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    picked=""
    case "$f" in
      tests/foundation/helpers/*|tests/foundation/fixtures/*)
        echo "changed: $f -> all of tests/foundation/lib" >&2; all=1; continue ;;
      tests/foundation/lib/*.bats)
        if [ -f "$root/$f" ]; then
          echo "changed: $f -> itself" >&2
          selected="$selected"$'\n'"$root/$f"
        else
          echo "changed: $f -> removed, nothing to run" >&2
        fi
        continue ;;
      skills/*)
        name="${f#skills/}"; name="${name%%/*}"
        name="$(printf '%s' "$name" | sed 's/[][\\.*^$+?(){}|]/\\&/g')"
        picked="$(grep -lE -- "skills/$name([^a-z0-9-]|\$)" "$lib"/*.bats 2>/dev/null || true)" ;;
      *)
        picked="$(grep -lF -- "$f" "$lib"/*.bats 2>/dev/null || true)" ;;
    esac
    case "$f" in
      skills/*|agents/*|conventions/*|commands/*)
        picked="$picked"$'\n'"$sweeps" ;;
    esac
    picked="$(printf '%s\n' "$picked" | sed '/^$/d' | sort -u)"
    if [ -z "$picked" ]; then
      echo "changed: $f -> no test names it" >&2
    else
      echo "changed: $f -> $(printf '%s\n' "$picked" | sed 's|.*/||' | tr '\n' ' ' | sed 's/ $//')" >&2
      selected="$selected"$'\n'"$picked"
    fi
  done <<< "$files"
  if [ "$all" -eq 1 ]; then
    printf '%s\n' "$lib"
    return 0
  fi
  printf '%s\n' "$selected" | sed '/^$/d' | sort -u
}

case "$target" in
  unit) bats "$lib" ;;
  all)  bats "${suites[@]}" ;;
  # Minutes of Gradle, so `all` leaves it out; `snippets` is run on its own and in CI.
  snippets) bats "$root/tests/foundation/snippets" ;;
  changed)
    list="$(changed_suites)"
    if [ "${2:-}" = "--list" ]; then
      [ -z "$list" ] || printf '%s\n' "$list"
      exit 0
    fi
    [ -n "$list" ] || exit 0
    chosen=()
    while IFS= read -r s; do chosen+=("$s"); done <<< "$list"
    bats "${chosen[@]}" ;;
  *)    echo "usage: $0 [unit|all|snippets|changed [--list]]" >&2; exit 2 ;;
esac
