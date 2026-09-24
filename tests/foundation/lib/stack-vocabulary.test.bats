#!/usr/bin/env bats
# A `## Stack` line is `- <Line label>: <value>` with a value `## Axes` lists; any other
# label or value is one spine-toolkit:stack-detect never reads, and its axis is asked on every task.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  M="$ROOT/skills/manifest/SKILL.md"
  SETUP="$ROOT/skills/kotlin-setup/SKILL.md"
  L="$ROOT/skills/kotlin-setup/locales"
  CHOICE="$ROOT/skills/architecture-choice/SKILL.md"
  INIT="$ROOT/agents/kotlin-init.md"
  CMD="$ROOT/commands/kotlin-init.md"
}

axis_values() {
  sed -n '/^## Axes$/,/^## Heuristics$/p' "$M" | grep -E "^$1[[:space:]]*=" \
    | sed 's/^[^=]*=//' | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

in_axis() { axis_values "$1" | grep -qxF -- "$2"; }

table_rows() {
  awk -v h="$1" '$0 == h {f = 1; next} f && /^\|[-| ]+\|$/ {next} f && /^\|/ {print; next} f {exit}' "$2"
}

cell() { awk -F'|' -v n="$(( $1 + 1 ))" '{ gsub(/^[ \t]+|[ \t]+$/, "", $n); print $n }'; }

ticks() { tr -d '`'; }

line_label() {
  table_rows '| Axis | Line label |' "$SETUP" | while IFS= read -r row; do
    [ "$(cell 1 <<<"$row" | ticks)" = "$1" ] && cell 2 <<<"$row" | ticks
  done
}

axes() {
  sed -n '/^## Axes$/,/^## Heuristics$/p' "$M" | grep -oE '^[a-z][a-z-]*[[:space:]]*=' \
    | grep -oE '^[a-z-]+' | grep -vx ecosystem
}

@test "every axis has one line label, and step 4 writes it" {
  n=0
  for a in $(axes); do
    [ "$(line_label "$a" | grep -c .)" -eq 1 ] || { echo "$a: $(line_label "$a" | grep -c .) line labels"; return 1; }
    n=$((n + 1))
  done
  [ "$n" -ge 9 ] || { echo "checked $n axes; the scan went vacuous"; return 1; }
  grep -qF '`- <Line label>: <value>`' "$SETUP" || { echo "step 4 does not write the line label"; return 1; }
  ! grep -qF '<Label>' "$SETUP" || { echo "a <Label> placeholder is still in kotlin-setup"; return 1; }
}

@test "every stack line the plugin names uses a line label" {
  labels="$(table_rows '| Axis | Line label |' "$SETUP" | cell 2 | ticks)"
  found="$(grep -rhoE '`- [A-Z][A-Za-z ]*:' "$ROOT/agents" "$ROOT/skills" "$ROOT/commands" | sed 's/^`- //; s/:$//' | sort -u)"
  [ "$(grep -c . <<<"$found")" -ge 5 ] || { echo "found $(grep -c . <<<"$found") labels; the scan went vacuous"; return 1; }
  while IFS= read -r l; do
    grep -qxF -- "$l" <<<"$labels" || { echo "\`- $l:\` is named somewhere but is no line label"; return 1; }
  done <<<"$found"
}

@test "a line labelled with a question label is rewritten to the line label, and reported" {
  grep -qF 'matches the text of an `auq_axis_<axis>_label` key in any of this skill'"'"'s locales' "$SETUP" \
    || { echo "step 2 has no rewrite rule for question labels"; return 1; }
  grep -qF '`report_axis_renamed`' "$SETUP" || { echo "the rewrite is not reported"; return 1; }
}

@test "the rewrite rule fires only on a label that is not already a line label" {
  grep -qF 'A label that is no line label but matches the text of' "$SETUP" \
    || { echo "step 2 still rewrites a correct line to itself"; return 1; }
}

@test "question labels are distinct within each locale" {
  for lang in en ru; do
    labels="$(awk '/^## auq_axis_[a-z]+_label$/ {getline; print}' "$L/$lang.md")"
    [ "$(grep -c . <<<"$labels")" -ge 9 ] || { echo "$lang: the scan went vacuous"; return 1; }
    dup="$(sort <<<"$labels" | uniq -d)"
    [ -z "$dup" ] || { echo "$lang: shared by two axes: $dup"; return 1; }
  done
}

@test "Axes by Target asks a KMP module no framework or async, and a Spring Boot server no DI" {
  rows="$(table_rows '| `target` | Asked (if still unresolved) |' "$SETUP")"
  kmp="$(grep -E '^\| KMP \|' <<<"$rows")"
  [ -n "$kmp" ] || { echo "no KMP row"; return 1; }
  ! grep -qE 'every axis|`framework`|`async`' <<<"$kmp" || { echo "KMP row: $kmp"; return 1; }
  grep -qF 'is `Spring Boot`, `di` is not asked and the line is `- DI: Spring`' "$SETUP" \
    || { echo "no Spring Boot DI rule"; return 1; }
  grep -qF 'is `Micronaut` or `Quarkus`, `di` is not asked and gets no line' "$SETUP" \
    || { echo "no Micronaut/Quarkus DI rule"; return 1; }
}

@test "every line architecture-choice writes into ## Stack is a catalog value" {
  n=0
  while IFS= read -r row; do
    arch="$(cell 2 <<<"$row" | ticks)"; di="$(cell 3 <<<"$row" | ticks)"
    [ "$arch" = "—" ] || in_axis architecture "$arch" || { echo "$(cell 1 <<<"$row") writes Architecture: $arch"; return 1; }
    [ "$di" = "—" ] || in_axis di "$di" || { echo "$(cell 1 <<<"$row") writes DI: $di"; return 1; }
    n=$((n + 1))
  done < <(table_rows '| Recommendation | `- Architecture:` | `- DI:` |' "$CHOICE")
  [ "$n" -ge 15 ] || { echo "checked $n rows; the table went missing"; return 1; }
  row="$(table_rows '| Recommendation | `- Architecture:` | `- DI:` |' "$CHOICE" | grep -F 'Matrix: CLI')"
  [ "$(cell 2 <<<"$row")" = "—" ] || { echo "a CLI gets an Architecture line: $row"; return 1; }
}

@test "architecture-choice writes no comment or objection into the config" {
  grep -qF '| Recommendation | `- Architecture:` | `- DI:` |' "$CHOICE" || { echo "the scan did not reach architecture-choice"; return 1; }
  for gone in '<!-- Chosen' '`Objection:' 'Done.md'; do
    ! grep -qF -- "$gone" "$CHOICE" || { echo "still there: $gone"; return 1; }
  done
}

@test "architecture-choice reads the target before asking it, and asks before replacing DI" {
  grep -qF 'a `- Target:` line answers the target surface axis' "$CHOICE" || { echo "target is re-asked"; return 1; }
  grep -qF 'An existing `- DI:` line with a different value is replaced only after the user confirms' "$CHOICE" \
    || { echo "DI is overwritten silently"; return 1; }
}

@test "kotlin-init asks the axes kotlin-setup's table names, and no other" {
  grep -qF '`kotlin-setup` → "Axes by Target"' "$INIT" || { echo "init does not take its axes from setup"; return 1; }
  init="$(table_rows '| Order | Axis | Options and default |' "$INIT" | cell 2 | ticks | sort -u)"
  setup="$( { echo target; table_rows '| `target` | Asked (if still unresolved) |' "$SETUP" | cell 2 | ticks | tr ',' '\n'; } \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep . | sort -u)"
  [ "$(grep -c . <<<"$setup")" -ge 9 ] || { echo "setup names $(grep -c . <<<"$setup") axes; the scan went vacuous"; return 1; }
  [ "$init" = "$setup" ] || { printf 'init:\n%s\nsetup:\n%s\n' "$init" "$setup"; return 1; }
}

@test "kotlin-init offers no value kept only for detection" {
  grep -qF '| Order | Axis | Options and default |' "$INIT" || { echo "the scan did not reach the dialog"; return 1; }
  for gone in 'Gradle Groovy' 'kotlinx-cli' 'API 21+'; do
    ! grep -qF -- "$gone" "$INIT" || { echo "init still offers $gone"; return 1; }
    ! grep -qF -- "$gone" "$CMD" || { echo "the command still names $gone"; return 1; }
  done
}

@test "kotlin-init generates from the dialog and hands setup only what it asked" {
  for gone in '`- Architecture:`' '`- Baseline:`' '| `- DI:` |' '`lang`, `mode`'; do
    ! grep -qF -- "$gone" "$INIT" || { echo "still there: $gone"; return 1; }
  done
  grep -qF '`lang` and `mode` are not passed' "$INIT" || { echo "the handoff does not say what it leaves out"; return 1; }
  grep -qF 'from the dialog'"'"'s answers, not from config lines' "$INIT" || { echo "no rule on where generation reads"; return 1; }
}

@test "kotlin-init names no later release" {
  n=0
  for f in "$INIT" "$CMD"; do
    [ -s "$f" ] || { echo "missing $f"; return 1; }
    n=$((n + 1))
    ! grep -qiE 'later release|territory, later|single-package initializer' "$f" || { echo "$f: $(grep -iE 'later release|territory, later|single-package initializer' "$f")"; return 1; }
  done
  [ "$n" -eq 2 ]
}

@test "a KMP module's no-UI answer travels from kotlin-init to kotlin-setup as ui = none" {
  grep -qF '`ui` = `none`' "$INIT" || { echo "kotlin-init does not name ui = none"; return 1; }
  line="$(grep -F '`ui` = `none`' "$SETUP")"
  [ -n "$line" ] || { echo "kotlin-setup does not name ui = none"; return 1; }
  grep -qF 'KMP' <<<"$line" || { echo "kotlin-setup's ui = none sentence does not name KMP: $line"; return 1; }
}

@test "the manifest's commonMain path row does not flag ui unconditionally" {
  row="$(sed -n '/^## Heuristics/,/^## Topics/p' "$M" | grep -F 'commonMain/')"
  [ -n "$row" ] || { echo "no commonMain/ path row"; return 1; }
  grep -qF '+ ui if' <<<"$row" || { echo "row: $row"; return 1; }
}

@test "kotlin-init's DI check allows the use-site annotations the framework requires" {
  grep -qF 'Graph declarations' "$INIT" || { echo "the check still bans every DI import"; return 1; }
  for a in '@HiltViewModel' '@AndroidEntryPoint' '`@Inject` constructors' '`koinViewModel()`'; do
    grep -qF -- "$a" "$INIT" || { echo "the check does not name $a"; return 1; }
  done
  ! grep -qF 'A `grep` for the DI import outside `di/`' "$INIT" || { echo "the old check is still there"; return 1; }
}

@test "every value kotlin-init's dialog names is one its row's axis lists" {
  n=0
  while IFS= read -r row; do
    axis="$(cell 2 <<<"$row" | ticks)"
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      in_axis "$axis" "$v" && { n=$((n + 1)); continue; }
      # Not a value: an axis, a command, a heading, a skill, or the no-UI answer kotlin-setup defines.
      axes | grep -qxF -- "$v" && continue
      case "$v" in /*|'#'*) continue ;; esac
      [ -d "$ROOT/skills/$v" ] && continue
      [ "$axis/$v" = ui/none ] && continue
      echo "row $axis names \`$v\`, which is not a $axis value"; return 1
    done < <(cell 3 <<<"$row" | grep -oE '`[^`]+`' | ticks)
  done < <(table_rows '| Order | Axis | Options and default |' "$INIT")
  [ "$n" -ge 14 ] || { echo "checked $n values; the scan went vacuous"; return 1; }
}
