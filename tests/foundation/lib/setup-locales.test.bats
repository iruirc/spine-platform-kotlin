#!/usr/bin/env bats
# kotlin-setup asks one question per axis by a key named after the axis. A new axis
# in the manifest with no label in the locales is a question that renders as its key.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  M="$ROOT/skills/manifest/SKILL.md"
  L="$ROOT/skills/kotlin-setup/locales"
}

@test "every non-ecosystem axis has a question label in both locales" {
  # Assignment lines only: a wrapped prose line under ## Axes can start lowercase too.
  axes="$(sed -n '/^## Axes/,/^## Heuristics/p' "$M" | grep -E '^[a-z][a-z-]*[[:space:]]*=' \
           | grep -oE '^[a-z][a-z-]*' | grep -v '^ecosystem$')"
  n="$(printf '%s\n' "$axes" | grep -c . || true)"
  [ "$n" -ge 9 ] || { echo "found $n axes; the scan went vacuous"; return 1; }
  for a in $axes; do
    for lang in en ru; do
      grep -q "^## auq_axis_${a}_label\$" "$L/$lang.md" || { echo "no auq_axis_${a}_label in $lang.md"; return 1; }
    done
  done
}

@test "the skill body names every locale key it ships" {
  # Two reference forms count: the literal key, and the `auq_axis_<axis>_label` template.
  body="$ROOT/skills/kotlin-setup/SKILL.md"
  for k in $(grep -oE '^## [a-z_]+' "$L/en.md" | sed 's/^## //'); do
    case "$k" in
      auq_axis_*_label) grep -q 'auq_axis_<axis>_label' "$body" && continue ;;
    esac
    grep -q "\`$k\`" "$body" || { echo "locale key named nowhere in the body: $k"; return 1; }
  done
}

@test "a label rewrite is reported with its old and new line, in both locales" {
  for lang in en ru; do
    grep -qx '## report_axis_renamed' "$L/$lang.md" || { echo "missing in $lang.md"; return 1; }
    grep -A1 -x '## report_axis_renamed' "$L/$lang.md" | grep -q '{old}.*{new}' \
      || { echo "$lang.md: the entry lacks {old} or {new}"; return 1; }
  done
}
