# The sweep lint, as functions a test file can call. A test that walks a source tree carries
# `# changed: sweep <dir>...` in its first 10 lines, naming each directory it walks, and
# `scripts/test-foundation.sh changed` runs it for a change under one of them.
#   sweep_expr <dir>      the grep -E expression that finds a walk of <dir> in a test file
#   sweep_walked <file>   the directories the file walks, in sweep order, one per line
#   sweep_findings <file> what is wrong with the file's mark, one finding per line; none when right

SWEEP_DIRS="skills agents conventions templates commands"

sweep_expr() {   # <dir>
  local d="$1"
  printf '%s\n' "$d/\\*|find [^|]*$d|for [a-z_]+ in [^;]*$d/|ROOT\\}?/$d/[^ \"/]*\\\$|ROOT\\}?/$d\""
}

sweep_walked() {   # <file>
  local d
  for d in $SWEEP_DIRS; do
    grep -qE "$(sweep_expr "$d")" "$1" && printf '%s\n' "$d"
  done
  return 0
}

sweep_findings() {   # <file>
  local f="$1" line words w d walked
  line="$(head -10 "$f" | grep -E '^# changed: sweep( |$)' | head -1 || true)"
  walked="$(sweep_walked "$f")"
  if [ -n "$line" ]; then
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
