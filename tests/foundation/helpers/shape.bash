# Structural checks shared by agents.test.bats and skills.test.bats. Each returns
# 1 with a one-line reason so a bats failure names the file and the missing part.

# The body is everything after the second `---`; cyrillic is legal only before it.
_body_after_frontmatter() { awk '/^---$/{c++; next} c>=2{print}' "$1"; }
# Cyrillic is detected by its UTF-8 lead bytes so this file carries no cyrillic itself
# and stays out of lint-i18n.sh's way: U+0400–U+047F encode as D0 80 … D1 BF.
_has_cyrillic() { LC_ALL=C grep -q $'[\xD0\xD1]'; }

assert_agent_shape() {
  local f="$1" name="$2"
  [ -f "$f" ] || { echo "no agent file: $f"; return 1; }
  [ "$(head -1 "$f")" = "---" ] || { echo "$f: no frontmatter"; return 1; }
  grep -qE "^name: ${name}\$" "$f" || { echo "$f: frontmatter name is not $name"; return 1; }
  grep -q 'Use when (en):' "$f" || { echo "$f: no English triggers"; return 1; }
  grep -q 'Use when (ru):' "$f" || { echo "$f: no Russian triggers"; return 1; }
  grep -qE '^model: (opus|sonnet)$' "$f" || { echo "$f: no model"; return 1; }
  grep -q '^\*\*First\*\*: Read CLAUDE-spine-toolkit.md' "$f" \
    || { echo "$f: does not read the project config first"; return 1; }
  local h
  for h in 'Invocation Context' 'Skills Reference (spine-platform-kotlin)' 'Skills Reference (core)' \
           'Related Agents (spine-platform-kotlin)' 'Output Structure' 'What You Never Do' 'Output Language'; do
    grep -q "^## $h" "$f" || { echo "$f: missing ## $h"; return 1; }
  done
  grep -q 'subagent_type=spine-platform-kotlin:<name>' "$f" \
    || { echo "$f: Related Agents does not state the namespaced dispatch form"; return 1; }
  ! _body_after_frontmatter "$f" | _has_cyrillic \
    || { echo "$f: cyrillic outside the frontmatter"; return 1; }
  ! grep -q 'kotlin-toolkit' "$f" || { echo "$f: names the retired plugin"; return 1; }
}

assert_skill_shape() {
  local dir="$1" name f
  name="$(basename "$dir")"; f="$dir/SKILL.md"
  [ -f "$f" ] || { echo "no SKILL.md in $dir"; return 1; }
  grep -qE "^name: ${name}\$" "$f" || { echo "$f: frontmatter name is not $name"; return 1; }
  grep -qE '^description: "Use when' "$f" || { echo "$f: description must start with Use when"; return 1; }
  grep -q '^> \*\*Related skills:\*\*' "$f" || { echo "$f: no Related skills block"; return 1; }
  grep -q '^## When to Use' "$f" || { echo "$f: no ## When to Use"; return 1; }
  grep -q '^## Common Mistakes' "$f" || { echo "$f: no ## Common Mistakes"; return 1; }
  ! _body_after_frontmatter "$f" | _has_cyrillic \
    || { echo "$f: cyrillic outside the frontmatter"; return 1; }
}
