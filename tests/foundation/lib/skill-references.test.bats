#!/usr/bin/env bats
# An agent reads a reference guide one section at a time: the section name comes from the
# SKILL.md load table, the path from beside the SKILL.md. Table, H2s and Contents must agree.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  GUIDES="$(ls "$ROOT"/skills/*/references/detailed-guide.md 2>/dev/null || true)"
  LOAD='`references/detailed-guide.md` lies beside this file; its `## Contents` names the sections — read only the ones the table points to.'
}

thirteen_guides() {
  n="$(grep -c . <<<"$GUIDES" || true)"
  [ "$n" -eq 13 ] || { echo "found $n guides, expected 13"; return 1; }
}

skill_of() { basename "$(dirname "$(dirname "$1")")"; }

h2s() {
  awk '/^[ \t]*(```|~~~)/ {fence = !fence; next}
       !fence && /^## / && $0 != "## Contents" {sub(/^## /, ""); print}' "$1"
}

contents() {
  awk '$0 == "## Contents" {f = 1; next} f && /^#/ {exit} f && NF {sub(/^- /, ""); print}' "$1"
}

# The last cell of each data row of the table under "## When To Load The Reference".
section_cells() {
  awk '$0 == "## When To Load The Reference" {f = 1; next} f && /^## / {exit} f && /^\|/' "$1" \
    | grep -vE '^\|[-| ]+\|$' | sed 1d | awk -F'|' '{print $(NF-1)}'
}

@test "a guide opens with its title and carries no frontmatter" {
  thirteen_guides
  bad=""
  while IFS= read -r g; do
    s="$(skill_of "$g")"
    [ "$(head -1 "$g")" = "# $s — detailed guide" ] || bad="$bad $s"
  done <<<"$GUIDES"
  [ -z "$bad" ] || { echo "first line is not '# <skill> — detailed guide':$bad"; return 1; }
}

@test "Contents follows the title and lists the guide's H2s in order" {
  thirteen_guides
  bad=""
  while IFS= read -r g; do
    s="$(skill_of "$g")"
    [ "$(sed 1d "$g" | grep -m1 .)" = "## Contents" ] || bad="$bad $s:no-Contents-after-the-title"
    [ -n "$(h2s "$g")" ] && [ "$(contents "$g")" = "$(h2s "$g")" ] || bad="$bad $s:Contents-differs-from-the-H2s"
  done <<<"$GUIDES"
  [ -z "$bad" ] || { echo "$bad"; return 1; }
}

@test "a guide's H2 carries no backticks, so a table can quote it" {
  thirteen_guides
  hits=""
  while IFS= read -r g; do
    hits="$hits$(h2s "$g" | grep -F '`' | sed "s|^| $(skill_of "$g"): |" || true)"
  done <<<"$GUIDES"
  [ -z "$hits" ] || { echo "$hits"; return 1; }
}

@test "the load table names every H2 of its guide and nothing else" {
  thirteen_guides
  bad=""
  while IFS= read -r g; do
    s="$(skill_of "$g")"
    cells="$(section_cells "$ROOT/skills/$s/SKILL.md")"
    [ -n "$cells" ] || { bad="$bad"$'\n'"$s: no load table"; continue; }
    extra="$(sed 's/`[^`]*`//g; s/[ ,]//g' <<<"$cells" | grep . || true)"
    [ -z "$extra" ] || bad="$bad"$'\n'"$s: a section cell holds more than backticked names: $extra"
    named="$(grep -oE '`[^`]+`' <<<"$cells" | tr -d '`' | LC_ALL=C sort -u)"
    heads="$(h2s "$g" | LC_ALL=C sort -u)"
    only_table="$(LC_ALL=C comm -23 <(printf '%s\n' "$named") <(printf '%s\n' "$heads") | paste -sd ';' -)"
    only_guide="$(LC_ALL=C comm -13 <(printf '%s\n' "$named") <(printf '%s\n' "$heads") | paste -sd ';' -)"
    [ -z "$only_table" ] || bad="$bad"$'\n'"$s: the table names what no H2 is: $only_table"
    [ -z "$only_guide" ] || bad="$bad"$'\n'"$s: no table row names: $only_guide"
  done <<<"$GUIDES"
  [ -z "$bad" ] || { echo "$bad"; return 1; }
}

@test "a SKILL.md loads its guide from beside itself" {
  thirteen_guides
  bad=""
  while IFS= read -r g; do
    s="$(skill_of "$g")"
    grep -qF -- "$LOAD" "$ROOT/skills/$s/SKILL.md" || bad="$bad $s:no-load-sentence"
    ! grep -qF 'rg -n' "$ROOT/skills/$s/SKILL.md" || bad="$bad $s:rg"
  done <<<"$GUIDES"
  [ -z "$bad" ] || { echo "$bad"; return 1; }
}

@test "no SKILL.md names a guide by a path from the plugin root" {
  n="$(ls "$ROOT"/skills/*/SKILL.md | wc -l | tr -d ' ')"
  [ "$n" -ge 25 ] || { echo "found $n SKILL.md files; the scan went vacuous"; return 1; }
  hits="$(grep -n 'skills/[a-z-]*/references' "$ROOT"/skills/*/SKILL.md || true)"
  [ -z "$hits" ] || { echo "$hits"; return 1; }
}

@test "a guide names no guide file, neither its own nor another skill's, by a self-referential rg command" {
  thirteen_guides
  hits=""
  while IFS= read -r g; do
    hits="$hits$(grep -n -e 'detailed-guide\.md' -e 'rg -n "\^## ' "$g" | sed "s|^| $(skill_of "$g"):|" || true)"
  done <<<"$GUIDES"
  [ -z "$hits" ] || { echo "$hits"; return 1; }
}
