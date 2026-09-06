#!/usr/bin/env bash
# Adapted from spine-toolkit scripts/lint-manifest.sh sha256:6740aec3de096e21ef4340b49b13b73efa251a77815ad65b414488cd7846f327
# Adapted from spine-toolkit's lint. Plugins share no code; update both or neither.
# Checks a platform plugin's manifest skill against the spine-toolkit contract.
# Validates the five tables' presence, Roles content (vocabulary, named agents
# exist, fan-out rows that core can actually match, no duplicate left-hand
# sides) and Entrypoints content (a named skill exists). Topics content is NOT
# checked here — a manifest may name topic skills that don't resolve within its
# own plugin as a teaching device (spine-toolkit's reference fixture does);
# real platforms get their Topics checked by their own test suite. Entrypoints
# is checked because core calls it by name at install time, where a typo is
# indistinguishable from the legitimate '—' and surfaces only after the config
# is already written.
# Usage: lint-manifest.sh <plugin-dir>
set -euo pipefail

plugin="${1:?usage: lint-manifest.sh <plugin-dir>}"
manifest="$plugin/skills/manifest/SKILL.md"
ROLES="architect developer tester reviewer refactorer validator security diagnostics init"
ENTRYPOINTS="setup"
violations=0

[ -f "$manifest" ] || { echo "no manifest skill at $manifest"; exit 1; }

for section in Roles Axes Heuristics Topics Entrypoints; do
  grep -q "^## $section\$" "$manifest" || { echo "missing table: $section"; violations=$((violations+1)); }
done

roles_block=$(sed -n '/^## Roles/,/^## /p' "$manifest")

# Restrict parsing to actual "role[axis=value]? = value" lines, not the prose
# paragraph above the table — a wrapped continuation line can start with a
# lowercase word (e.g. "demonstrated below...") and a backticked example like
# `plugin:agent` in prose would otherwise be mistaken for a real reference.
# `[[:space:]]*`, not literal spaces, so tab-aligned tables parse too.
# `|| true`: grep exits 1 on zero matches (an emptied Roles table), which
# would otherwise abort the whole script here under `set -e`, before a
# single role gets reported missing.
assignments=$(grep -E '^[a-z][a-z-]*(\[[^]]+\])?[[:space:]]*=' <<<"$roles_block" || true)

for role in $ROLES; do
  grep -qE "^${role}(\[[^]]+\])?[[:space:]]*=" <<<"$assignments" \
    || { echo "role not declared (map it or write '—'): $role"; violations=$((violations+1)); }
done

while read -r declared; do
  grep -qw "$declared" <<<"$ROLES" \
    || { echo "role outside the core vocabulary: $declared"; violations=$((violations+1)); }
done < <(grep -oE '^[a-z][a-z-]*' <<<"$assignments" | sort -u)

# The namespace half of `plugin:agent` travels into subagent dispatch verbatim, so a
# manifest may only name agents of the plugin that ships it: checking the file alone
# accepts any prefix, and a plugin rename then dispatches a name resolving to nothing.
# Parsed as JSON, not read line by line: a nested `author.name` listed first wins
# a `^"name"` grep, and a minified file defeats it entirely.
own_name="$(python3 - "$plugin/.claude-plugin/plugin.json" <<'PY' 2>/dev/null || true
import json, sys
try:
    v = json.load(open(sys.argv[1]))["name"]
    print(v if isinstance(v, str) else "")
except Exception:
    pass
PY
)"
[ -n "$own_name" ] \
  || { echo "cannot read a top-level \"name\" from $plugin/.claude-plugin/plugin.json"; violations=$((violations+1)); }

while read -r ref; do
  [ -z "$own_name" ] || [ "${ref%%:*}" = "$own_name" ] \
    || { echo "manifest names an agent outside this plugin's namespace (expected $own_name:): $ref"; violations=$((violations+1)); }
  [ -f "$plugin/agents/${ref#*:}.md" ] \
    || { echo "manifest names an agent with no file: $ref"; violations=$((violations+1)); }
done < <(grep -oE '[a-z][a-z0-9-]*:[a-z][a-z0-9-]*' <<<"$assignments" | sort -u)

# `## Axes` shares the `name = value` grammar, so the window is bounded the same way
# the Roles one is. Its keys are what the fan-out checks below are decided against:
# core resolves an axis-qualified row only for an axis stack-detect returns, which is
# every declared axis except `ecosystem` (excluded from detection by construction).
axes_block=$(sed -n '/^## Axes/,/^## /p' "$manifest")
axes=$(grep -E '^[a-z][a-z-]*[[:space:]]*=' <<<"$axes_block" || true)

trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; printf '%s' "${v%"${v##*[![:space:]]}"}"; }

# A fan-out row that can never match resolves the role to '—' on every task of every
# project, and the only symptom is a stage announcing a deviation. Three ways to write
# one, all decidable here. Duplicates are the fourth: core takes the first row and the
# rest are dead, which no runtime signal distinguishes from a typo in the value.
seen=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  [[ "$line" =~ ^([a-z][a-z-]*)(\[[^]]*\])?[[:space:]]*= ]] || continue
  lhs="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  if grep -qxF "$lhs" <<<"$seen"; then
    echo "duplicate Roles row (core reads the first; the rest are dead): $lhs"
    violations=$((violations+1))
  fi
  seen="$seen$lhs"$'\n'

  [[ "$line" =~ ^[a-z][a-z-]*\[([^]=]*)=([^]]*)\] ]] || continue
  axis=$(trim "${BASH_REMATCH[1]}")
  value=$(trim "${BASH_REMATCH[2]}")
  if [ "$axis" = "ecosystem" ]; then
    echo "fan-out on 'ecosystem', which core never resolves — the row can never match: $lhs"
    violations=$((violations+1))
    continue
  fi
  # Exact string compare, not `grep -E "^$axis"`: a regex metacharacter in the
  # axis name matched a different row and reported the manifest OK.
  allowed=""
  while IFS= read -r arow; do
    [ -n "$arow" ] || continue
    [ "$(trim "${arow%%=*}")" = "$axis" ] || continue
    allowed="${arow#*=}"
    break
  done <<<"$axes"
  if [ -z "$(trim "$allowed")" ]; then
    echo "fan-out on an axis '## Axes' does not declare: $lhs"
    violations=$((violations+1))
    continue
  fi
  found=0
  IFS=',' read -ra allowed_values <<<"$allowed"
  for v in "${allowed_values[@]}"; do
    [ "$(trim "$v")" = "$value" ] && found=1
  done
  [ "$found" -eq 1 ] || {
    echo "fan-out on a value '## Axes' does not list for '$axis': $lhs"
    violations=$((violations+1))
  }
done <<<"$assignments"

# A role line's RHS must be an em-dash (declared absent) or a plugin:agent
# reference — not empty. `role =` with nothing after it is neither a mapping
# nor an explicit absence; the two are indistinguishable to core at runtime,
# so this is the only place the difference can be caught.
while IFS= read -r line; do
  [[ "$line" =~ ^([a-z][a-z-]*)(\[[^]]+\])?[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
  # The qualifier belongs in the message: a role with several fan-out rows reports the
  # same name from each of them, and the bare name does not say which row is broken.
  role_name="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  rhs="${BASH_REMATCH[3]}"
  rhs="${rhs%"${rhs##*[![:space:]]}"}"  # trim trailing whitespace
  case "$rhs" in
    "—") ;;
    *)
      # Digits are legal in a plugin or agent name (`vue3-platform:vue3-architect`);
      # rejecting them here also made the extraction above match the post-digit
      # fragment, reporting an agent the manifest never named.
      if [[ "$rhs" =~ ^[a-z][a-z0-9-]*:[a-z][a-z0-9-]*$ ]]; then
        :
      elif [ -z "$rhs" ]; then
        echo "role mapped to an empty value (write a plugin:agent reference or '—'): $role_name"
        violations=$((violations+1))
      else
        echo "role mapped to a malformed value '$rhs' (expected plugin:agent or '—'): $role_name"
        violations=$((violations+1))
      fi
      ;;
  esac
done <<<"$assignments"

# Entrypoints: `name = `skill`` or `name = —`. The skill is this plugin's own,
# so it must resolve to skills/<name>/SKILL.md here. Same window discipline as
# Roles — assignment lines only, so the prose above the table cannot pollute it.
# `,/^## /p`, not `,$p`: bounded like the Roles window above. `## Axes` rows share the
# `name = value` grammar, so an unbounded window would read every axis as a malformed
# entrypoint the moment this table stops being last. Still runs to EOF while it is.
entry_block=$(sed -n '/^## Entrypoints/,/^## /p' "$manifest")
entries=$(grep -E '^[a-z][a-z-]*[[:space:]]*=' <<<"$entry_block" || true)

while IFS= read -r line; do
  [ -n "$line" ] || continue
  [[ "$line" =~ ^([a-z][a-z-]*)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
  entry_name="${BASH_REMATCH[1]}"
  rhs="${BASH_REMATCH[2]}"
  rhs="${rhs%"${rhs##*[![:space:]]}"}"  # trim trailing whitespace
  # An unknown name is a row core will never call, which reads exactly like a
  # correctly declared one. A MISSING `setup` row is not checked: the contract
  # declares it, like the em dash, a supported shape.
  grep -qw "$entry_name" <<<"$ENTRYPOINTS" \
    || { echo "entrypoint outside the core vocabulary (core never calls it): $entry_name"; violations=$((violations+1)); }
  case "$rhs" in
    "—") ;;
    '`'*'`')
      skill="${rhs//\`/}"
      [ -f "$plugin/skills/$skill/SKILL.md" ] \
        || { echo "entrypoint names a skill with no SKILL.md: $entry_name = $skill"; violations=$((violations+1)); }
      ;;
    *)
      echo "entrypoint mapped to a malformed value '$rhs' (expected \`skill\` or '—'): $entry_name"
      violations=$((violations+1))
      ;;
  esac
done <<<"$entries"

[ "$violations" -eq 0 ] || exit 1
echo "manifest OK: $plugin"
