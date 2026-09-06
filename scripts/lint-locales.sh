#!/usr/bin/env bash
# Adapted from spine-toolkit scripts/lint-locales.sh sha256:6f91002d474d4ffa68ce13b7c8b153c4ca2ed6fa01eef52a02cf455d3a17ede0
# Adapted from spine-toolkit's lint. Plugins share no code; update both or neither.
set -euo pipefail

# Paths below are repo-relative: anchor the cwd so a run from elsewhere
# cannot scan the wrong tree and report a pass.
cd "$(dirname "$0")/.."

# A key present in both files with an empty body is parity-clean and useless:
# structure is comparable across languages, values are not, so this is the one
# value check that generalizes.
keys_with_no_value() {
  python3 - "$1" <<'PYEOF'
import re, sys
blocks = re.split(r'^## ', open(sys.argv[1], encoding='utf-8').read(), flags=re.M)[1:]
print(' '.join(b.split('\n', 1)[0].strip() for b in blocks if not b.split('\n', 1)[-1].strip()))
PYEOF
}

violations=0
# Iterate the locale DIRECTORIES, not en.md: iterating en.md drops a skill that
# lost that file from the run entirely, which is the failure this lint is for.
for dir in skills/*/locales; do
  [ -d "$dir" ] || continue
  en="$dir/en.md"
  ru="$dir/ru.md"
  missing=0
  for f in "$en" "$ru"; do
    [ -f "$f" ] || { echo "Missing $(basename "$f") in $dir/"; violations=$((violations + 1)); missing=1; }
  done
  [ "$missing" -eq 0 ] || continue

  # Existence only, not content-identity: a workspace skill legitimately resolves
  # a different config and so states different steps (conventions/i18n.md).
  skill="${dir%/locales}/SKILL.md"
  if ! grep -q '^## Language Resolution' "$skill"; then
    echo "Localized skill with no '## Language Resolution' section: $skill"
    violations=$((violations + 1))
  fi

  diff_out=$(diff <(grep '^## ' "$en" | sort) <(grep '^## ' "$ru" | sort) || true)
  if [ -n "$diff_out" ]; then
    echo "Key parity mismatch in $dir/:"
    echo "$diff_out"
    violations=$((violations + 1))
  fi

  for f in "$en" "$ru"; do
    empty=$(keys_with_no_value "$f")
    [ -z "$empty" ] || { echo "Key(s) with no value in $f: $empty"; violations=$((violations + 1)); }
  done
done

if [ "$violations" -gt 0 ]; then
  echo
  echo "Locale parity lint failed: $violations issue(s)"
  exit 1
fi

echo "Locale parity lint passed: all locales in sync"
