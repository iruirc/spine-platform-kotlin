#!/usr/bin/env bash
# Adapted from spine-toolkit scripts/lint-core-refs.sh sha256:5d36a2ec78516c22bf741604c77a7afc1db2a936df72ac1f060412e4d68358ff
# Adapted from spine-toolkit's lint. Plugins share no code; update both or neither.
# Checks a platform plugin's references to core skills against the version floor
# the platform itself declares. Two rules: a namespaced reference must resolve to
# a skill that exists at the floor, and a hyphenated core skill name must not be
# written bare. The floor is read from the platform's own plugin.json — a
# string-form dependency declares none, which is itself the first violation.
# Usage: lint-core-refs.sh <plugin-dir> --core <path> [--ref <git-ref>]
set -euo pipefail

CORE="spine-toolkit"

plugin=""; core=""; ref=""; ref_given=0
while [ $# -gt 0 ]; do
  case "$1" in
    --core) core="${2:-}"; [ -n "$core" ] || { echo "--core needs a path" >&2; exit 2; }; shift 2 ;;
    --ref)  ref="${2:-}";  [ -n "$ref" ]  || { echo "--ref needs a git ref" >&2; exit 2; }; ref_given=1; shift 2 ;;
    -*)     echo "unknown option: $1" >&2; exit 2 ;;
    *)      [ -z "$plugin" ] || { echo "unexpected argument: $1" >&2; exit 2; }; plugin="$1"; shift ;;
  esac
done

[ -n "$plugin" ] || { echo "usage: lint-core-refs.sh <plugin-dir> --core <path> [--ref <git-ref>]" >&2; exit 2; }
# No silent skip: the check needs core's skill list, and a run without one would
# report success having compared nothing.
[ -n "$core" ] || { echo "--core is required: the check needs core's skill list" >&2; exit 2; }

violations=0
pj="$plugin/.claude-plugin/plugin.json"
[ -f "$pj" ] || { echo "no plugin.json at $pj"; exit 1; }

# Parsed as JSON, not grepped: the object and string forms are both legal JSON and
# only the object one carries a range, which is the whole distinction being made.
floor="$(python3 - "$pj" "$CORE" <<'PY' || true
import json, re, sys
try:
    deps = json.load(open(sys.argv[1])).get("dependencies", [])
except Exception:
    sys.exit(0)
for d in deps:
    if isinstance(d, dict) and d.get("name") == sys.argv[2]:
        m = re.search(r">=\s*(\d+\.\d+\.\d+)", d.get("version", "") or "")
        if m:
            print(m.group(1))
        break
PY
)"

if [ -z "$floor" ]; then
  echo "dependency on $CORE declares no version floor (use the object form with a >= range)"
  violations=$((violations+1))
fi

[ -n "$ref" ] || ref="$floor"

if [ -n "$ref" ] && git -C "$core" rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then
  core_skills="$(git -C "$core" ls-tree --name-only "$ref" skills/ | sed 's|^skills/||')"
  checked_against="$CORE $ref"
else
  # An explicit --ref asks for an exact check, so a ref that resolves to nothing is
  # a wrong invocation; only the floor-derived one is allowed to degrade (D-5).
  [ "$ref_given" -eq 0 ] || { echo "--ref $ref does not resolve in $core" >&2; exit 2; }
  core_skills="$(ls "$core/skills" 2>/dev/null || true)"
  have="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
          "$core/.claude-plugin/plugin.json" 2>/dev/null || echo "unknown version")"
  checked_against="$CORE $have as it sits at $core — NOT the declared floor ${floor:-<none>}"
fi

[ -n "$core_skills" ] || { echo "no skills found in $core — is that a $CORE checkout?"; exit 1; }

# Rule 1 (contract: core skills are named `spine-toolkit:<skill>`). Read anywhere
# in the file, frontmatter included — a description that names a skill is as much
# a reference as a body sentence, and both break the same way.
# `done < <(...)`, not a pipe: a pipe puts the counter in a subshell and every
# violation found here would be forgotten by the exit test below.
while IFS= read -r hit; do
  name="${hit##*:}"
  loc="${hit%:$CORE:$name}"
  grep -qxF "$name" <<<"$core_skills" \
    || { echo "$loc names $CORE:$name, which does not exist in $checked_against"; violations=$((violations+1)); }
done < <(grep -rnoE "$CORE:[a-z][a-z0-9-]*" "$plugin/agents" "$plugin/skills" 2>/dev/null || true)

# Rule 2, the drift detector: without it rule 1 holds only until the next
# paragraph someone writes bare. Hyphenated names only — core's single-word
# vocabulary (`lang`, `setup`, `orchestrator`) legitimately appears bare as a
# dispatch field or an Entrypoints row, and 11 of the platform's occurrences are
# exactly that. The cost is a known blind spot, named in the spec as D-11.
# The pattern needs a backtick on both sides, so `spine-toolkit:ops-checklist`
# cannot match: the colon is outside the character class.
while IFS= read -r hit; do
  tok="${hit##*:}"
  loc="${hit%:$tok}"
  name="${tok//\`/}"
  grep -qxF "$name" <<<"$core_skills" || continue
  echo "$loc names \`$name\` bare; core skills are written $CORE:$name"
  violations=$((violations+1))
done < <(grep -rnoE '`[a-z][a-z0-9]*(-[a-z0-9]+)+`' "$plugin/agents" "$plugin/skills" 2>/dev/null || true)

[ "$violations" -eq 0 ] || { echo "checked against $checked_against"; exit 1; }
echo "core refs OK: $plugin (checked against $checked_against)"
