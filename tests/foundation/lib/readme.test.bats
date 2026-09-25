#!/usr/bin/env bats
# README.md restates two facts other files own — the core range in plugin.json and the manifest's
# tables — and nothing moves the copy when the owner changes.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
}

@test "the README quotes the core range plugin.json declares" {
  run python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["dependencies"]; print([x["version"] for x in d if x["name"]=="spine-toolkit"][0])' "$ROOT/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qF -- "- \`spine-toolkit\` \`$output\`" "$ROOT/README.md" || { echo "README does not quote $output"; return 1; }
}

@test "the README's manifest table names every table the manifest declares" {
  declared="$(grep -E '^## ' "$ROOT/skills/manifest/SKILL.md" | LC_ALL=C sort)"
  listed="$(grep -oE '^\| `## [^`]+`' "$ROOT/README.md" | sed 's/^| `//; s/`$//' | LC_ALL=C sort)"
  [ "$declared" = "$listed" ] || {
    echo "assumption violated: the README's manifest table does not list exactly the manifest's H2s"
    printf 'manifest:\n%s\nREADME:\n%s\n' "$declared" "$listed"
    return 1
  }
}

@test "every skill directory is named somewhere in the README" {
  n="$(ls "$ROOT/skills" | wc -l | tr -d ' ')"
  [ "$n" -ge 25 ] || { echo "found $n skills; the scan went vacuous"; return 1; }
  missing=""
  for s in $(ls "$ROOT/skills"); do
    grep -qF -- "$s" "$ROOT/README.md" || missing="$missing $s"
  done
  [ -z "$missing" ] || { echo "skills missing from README.md:$missing"; return 1; }
}

# Checks every "<n> architecture and infrastructure skills" ($1=skills) or "<n> tables" ($1=tables)
# in the README against $2, the count written out in words; prints each count that disagrees.
readme_counts() {
  python3 - "$ROOT/README.md" "$1" "$2" <<'PY'
import re, sys
path, kind, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
ones = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
tens = "twenty thirty forty fifty sixty seventy eighty ninety".split()
words = ones + [t + ("-" + o if o != "zero" else "") for t in tens for o in ones[:10]]
tail = r" (?:standalone )?architecture and infrastructure (?:knowledge )?skills\b" if kind == "skills" else r" tables\b"
num = "|".join(sorted(words[1:], key=len, reverse=True))
found = [m.group(1).lower() for m in re.finditer(r"\b(" + num + r")\b" + tail, " ".join(open(path, encoding="utf-8").read().split()), re.I)]
if not found:
    sys.exit(f"no {kind} count found in README.md; the scan went vacuous")
for w in found:
    if w != words[n]:
        print(f"README.md says {w}; the count is {n} ({words[n]})")
PY
}

@test "the README counts the knowledge skills skills/ holds" {
  n="$(ls "$ROOT/skills" | grep -cvxE 'manifest|kotlin-setup')"
  run readme_counts skills "$n"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "the README counts the tables the manifest declares" {
  n="$(grep -cE '^## ' "$ROOT/skills/manifest/SKILL.md")"
  run readme_counts tables "$n"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$output"; return 1; }
}
