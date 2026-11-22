#!/usr/bin/env bash
# Adapted from spine-toolkit scripts/lint-locales.sh sha256:de71757d21708fbe5a3591558192b879b96f60bf69afaab9851f5cdc8a2897ae
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

# Russian strings address the user with the informal "ty", never the formal "vy"
# (conventions/i18n.md, Russian address form). Grammar is out of reach, so this
# checks words: the "vy" pronouns, and a word ending in the plural imperative
# endings "-ite", "-yte", "-'te". A noun in the prepositional case can end the
# same way ("in the commit"); such a noun goes in NOT_IMPERATIVE. The words are
# \u escapes because scripts/lint-i18n.sh keeps Cyrillic out of this file.
formal_address() {
  python3 - "$1" <<'PYEOF'
import re, sys
CYR = '\u0400-\u04ff'
VY = re.compile('(?<![%s])(\u0432\u044b|\u0432\u0430\u0441|\u0432\u0430\u043c|\u0432\u0430\u043c\u0438|\u0432\u0430\u0448[%s]*|[%s]+(?:\u0438\u0442\u0435|\u0439\u0442\u0435|\u044c\u0442\u0435))(?![%s])' % (CYR, CYR, CYR, CYR), re.I)
NOT_IMPERATIVE = {
    '\u043a\u043e\u043c\u043c\u0438\u0442\u0435',  # commit, prepositional
    '\u043b\u0438\u043c\u0438\u0442\u0435',  # limit, prepositional
    '\u0441\u0430\u0439\u0442\u0435',  # site, prepositional
    '\u0431\u0430\u0439\u0442\u0435',  # byte, prepositional
}
path = sys.argv[1]
for n, line in enumerate(open(path, encoding='utf-8'), 1):
    if line.startswith('#'):
        continue
    words = [w for w in VY.findall(line) if w.lower() not in NOT_IMPERATIVE]
    if words:
        print(f'{path}:{n}: formal address ({", ".join(words)}): {line.strip()}')
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

  formal=$(formal_address "$ru")
  [ -z "$formal" ] || { echo "$formal"; violations=$((violations + 1)); }
done

if [ "$violations" -gt 0 ]; then
  echo
  echo "Locale parity lint failed: $violations issue(s)"
  exit 1
fi

echo "Locale parity lint passed: all locales in sync"
