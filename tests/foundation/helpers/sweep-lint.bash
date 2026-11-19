# The sweep lint, as functions a test file can call. A test that walks a source tree carries
# `# changed: sweep <dir>...` in its first 10 lines, naming each directory it walks, and
# `scripts/test-foundation.sh changed` runs it for a change under one of them.
#   sweep_expr <dir>      the grep -E expression that finds a walk of <dir> in a test file
#   sweep_walked <file>   the directories the file walks, in sweep order, one per line. A glob under
#                         a directory (<dir>/<prefix>*) walks it. A recursive
#                         grep, a find or an ls-files whose target is the repository root itself
#                         ("$ROOT", not "$ROOT/<dir>"), and a `git -C ... grep`, walk every directory;
#                         a recursive grep handed bare directory words walks each of them.
#   sweep_findings <file> what is wrong with the file's mark, one finding per line; none when right

SWEEP_DIRS="skills agents conventions templates commands"

sweep_expr() {   # <dir>
  local d="$1"
  printf '%s\n' "$d/[^ ]*\\*|find [^|]*$d|for [a-z_]+ in [^;]*$d/|ROOT\\}?/$d/[^ \"/]*\\\$|ROOT\\}?/$d\""
}

# The file's code, comment-only lines dropped: a comment that names workflows/wf_*.json walks nothing.
_sweep_code() {   # <file>
  grep -vE '^[[:space:]]*#' "$1" || true
}

# The same with backslash-continued lines joined, so a command split over lines reads as one.
_sweep_joined() {   # <file>
  _sweep_code "$1" | awk '{ if (sub(/\\$/, "")) buf = buf $0 " "; else { print buf $0; buf = "" } } END { if (buf != "") print buf }'
}

# A recursive grep: the flag may sit in any cluster, `-rn`, `-n -r`, `-R`, or be --recursive.
_SWEEP_GREP_R='grep( .*)? (-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)( |$)'
# The repository root itself, "$ROOT", $ROOT or ${ROOT}, and not "$ROOT/<dir>" or "$ROOT"/<dir>.
_SWEEP_ROOT='\$\{?ROOT\}?("([^/A-Za-z0-9_]|$)|[^/A-Za-z0-9_"]|$)'

sweep_walked() {   # <file>
  local d code joined whole=0
  code="$(_sweep_code "$1")"
  joined="$(_sweep_joined "$1")"
  if grep -qE "($_SWEEP_GREP_R|find |ls-files).*$_SWEEP_ROOT|git -C [^ ]+ (grep|ls-files)" <<<"$joined"; then
    whole=1
  fi
  for d in $SWEEP_DIRS; do
    if [ "$whole" -eq 1 ] || grep -qE "$(sweep_expr "$d")" <<<"$code" ||
       grep -qE "$_SWEEP_GREP_R.* $d( |\$)" <<<"$joined"; then
      printf '%s\n' "$d"
    fi
  done
  return 0
}

sweep_findings() {   # <file>
  local f="$1" line words w d walked
  line="$(head -10 "$f" | grep -E '^# changed: sweep([[:blank:]]|$)' | head -1 || true)"
  walked="$(sweep_walked "$f")"
  if [ -n "$line" ]; then
    case "$line" in *$'\t'*) echo "the mark has a tab: separate the directories with spaces" ;; esac
    words="${line#\# changed: sweep}"
    # shellcheck disable=SC2086
    set -- $words
    [ $# -gt 0 ] || echo "a bare sweep mark: name the directories the file walks"
    for w in "$@"; do
      case " $SWEEP_DIRS " in
        *" $w "*) grep -qx "$w" <<<"$walked" || echo "the mark names $w, which the file never walks" ;;
        *) echo "the mark has an unknown word '$w' (directories: $SWEEP_DIRS)" ;;
      esac
    done
  else
    set --
  fi
  for d in $walked; do
    case " $* " in *" $d "*) ;; *) echo "walks $d but the mark does not name it" ;; esac
  done
  return 0
}
