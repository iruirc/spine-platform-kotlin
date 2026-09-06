#!/usr/bin/env bash
# Adapted from spine-toolkit scripts/lint-i18n.sh sha256:6d6684c9beef8a053143482291eb5ae868505381b4e6dfd7455ee468f08159fd
# Adapted from spine-toolkit's lint. Plugins share no code; update both or neither.
set -euo pipefail

# Paths below are repo-relative: anchor the cwd so a run from elsewhere
# cannot scan the wrong tree and report a pass.
cd "$(dirname "$0")/.."

# Allowed cyrillic locations:
#   skills/*/locales/ru.md           (Russian locale strings; en.md is checked)
#   conventions/i18n.md              (canonical multilingual examples)
#   any *.ru.md anywhere             (Russian-only mirrors)
#   skills/<name>/SKILL.md           (only inside frontmatter description: bilingual triggers)
#   agents/<name>.md                 (only inside frontmatter description: bilingual triggers)
#   commands/<name>.md               (only inside frontmatter description: bilingual one-line)
#
# Anything else with cyrillic chars is a violation. Scanned file types: md, json,
# yml, yaml, js, sh, bats, zsh — an extensionless file is out of scope, since the
# reader here would have to guess whether it is text.

violations=0
while IFS= read -r -d '' f; do
  case "$f" in
    *.ru.md) continue ;;
    ./skills/*/locales/ru.md) continue ;;
    ./conventions/i18n.md) continue ;;
    ./.git/*) continue ;;
    # Defines the cyrillic range it searches for, so it matches itself.
    ./scripts/lint-i18n.sh) continue ;;
  esac

  # For SKILL.md / agents/*.md / commands/*.md, allow cyrillic ONLY inside the
  # frontmatter description block (between the first two --- lines).
  case "$f" in
    ./skills/*/SKILL.md|./agents/*.md|./commands/*.md)
      python3 - "$f" <<'PY' || violations=$((violations + 1))
import re, sys
path = sys.argv[1]
lines = open(path, encoding='utf-8').read().split('\n')
# The frontmatter is the block the file OPENS with, and it ends at the first line
# that is neither a YAML key nor an indented continuation. Merely counting `---`
# let a body thematic break stand in for a missing closing fence, so a file with
# one stayed exempt from the check this exception is carved out of.
close = None
if lines and lines[0].strip() == '---':
    for i, line in enumerate(lines[1:], 1):
        if line.strip() == '---':
            close = i
            break
        if line.strip() and not line[:1].isspace() and not re.match(r'[A-Za-z_][\w.-]*\s*:', line):
            break
if close is None:
    print(f'{path}:1: malformed frontmatter — cyrillic here cannot be checked')
    sys.exit(1)
for i, line in enumerate(lines[close + 1:], close + 2):
    if any('А' <= c <= 'я' or c in 'ёЁ' for c in line):
        print(f'{path}:{i}: cyrillic outside frontmatter: {line.rstrip()}')
        sys.exit(1)
PY
      ;;
    *)
      python3 - "$f" <<'PY' || violations=$((violations + 1))
import sys
path = sys.argv[1]
text = open(path, encoding='utf-8').read()
for i, line in enumerate(text.split('\n'), 1):
    if any('А' <= c <= 'я' or c in 'ёЁ' for c in line):
        print(f'{path}:{i}: cyrillic in non-localized file: {line.rstrip()}')
        sys.exit(1)
PY
      ;;
  esac
done < <(find . -type f \( -name '*.md' -o -name '*.json' -o -name '*.yml' -o -name '*.yaml' \
  -o -name '*.js' -o -name '*.sh' -o -name '*.bats' -o -name '*.zsh' \) -print0)

if [ "$violations" -gt 0 ]; then
  echo
  echo "i18n lint failed: $violations file(s) with disallowed cyrillic"
  exit 1
fi

echo "i18n lint passed: no disallowed cyrillic"
