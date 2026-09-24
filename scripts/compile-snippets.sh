#!/usr/bin/env bash
# Compile the Kotlin blocks marked for it in skills/*/SKILL.md and skills/*/references/detailed-guide.md
# in the Gradle sandbox tests/snippets/, and check marked TOML blocks against its version catalog.
# Usage: scripts/compile-snippets.sh [--emit-only DIR] [root]    (root defaults to this plugin)
# A marker, <!-- compile: <module>[-test] --> above a kotlin fence or <!-- compile: catalog --> above a
# toml fence, starts at column 0. A file's blocks of one marker compile as one unit, after the stubs in
# tests/snippets/<skill>/<SKILL|detailed-guide>.<marker>.kt when that file exists.
# Exit: 0 every unit compiles, 1 a unit does not, 2 the input, the toolchain or the sandbox is wrong.
set -euo pipefail

die() { echo "compile-snippets: $*" >&2; exit 2; }

emit=""
if [ "${1:-}" = "--emit-only" ]; then
  [ -n "${2:-}" ] || die "--emit-only needs a directory"
  emit="$2"; shift 2
fi
plugin="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
root_arg="${1:-$plugin}"
root="$(cd -- "$root_arg" 2>/dev/null && pwd)" || die "no such root: $root_arg"
sandbox="$plugin/tests/snippets"
catalog="$sandbox/gradle/libs.versions.toml"
[ -f "$catalog" ] || die "no version catalog at $catalog"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd -- "$tmp" && pwd -P)"
units="$tmp/units"
if [ -n "$emit" ]; then
  mkdir -p "$emit" || die "cannot create $emit"
  [ -z "$(ls -A "$emit")" ] || die "$emit is not empty"
  units="$(cd -- "$emit" && pwd -P)"
fi
maps="$units/.maps"
mkdir -p "$units" "$maps"
: > "$tmp/units.list"; : > "$tmp/errors"; : > "$tmp/drift"

extract='
BEGIN {
  n = split("jvm android kmp spring ktor net", m, " ")
  for (i = 1; i <= n; i++) { known[m[i]] = 1; known[m[i] "-test"] = 1 }
  while ((getline line < catalog) > 0) {
    line = norm(line)
    if (line == "") continue
    if (line ~ /^\[.*\]$/) { sec = line; continue }
    have[sec SUBSEP line] = 1
  }
  sec = ""
}
function norm(s) { sub(/[ \t]+#.*$/, "", s); sub(/^#.*$/, "", s); sub(/[ \t]+$/, "", s); return s }
function err(msg) { print "ERR|" rel ":" FNR ": " msg }
function keep(name, kind, text, origin) {
  if (kind == "import" || kind == "file") { if ((name SUBSEP text) in seen) return; seen[name SUBSEP text] = 1 }
  k = ++cnt[name SUBSEP kind]; txt[name SUBSEP kind SUBSEP k] = text; org[name SUBSEP kind SUBSEP k] = origin
}
pending {
  pending = 0
  want = (name == "catalog") ? "toml" : "kotlin"
  if ($0 !~ ("^```" want "[ \t]*$")) { err("a compile marker must sit directly above a " want " fence"); next }
  if (name == "catalog") { cat = 1; sec = ""; catblocks++; next }
  if (!(name in blocks)) { order[++names] = name; blocks[name] = 0 }
  blocks[name]++; inblock = 1; next
}
(inblock || cat) && /^```[ \t]*$/ { inblock = 0; cat = 0; next }
cat {
  line = norm($0)
  if (line == "") next
  if (line ~ /^\[.*\]$/) { sec = line; next }
  if (sec == "") { print "DRIFT|" rel ":" FNR ": no [section] above this line"; next }
  if (!((sec SUBSEP line) in have)) print "DRIFT|" rel ":" FNR ": not in " sec " of tests/snippets/gradle/libs.versions.toml: " line
  next
}
inblock {
  if ($0 ~ /^@file:/) keep(name, "file", $0, rel ":" FNR)
  else if ($0 ~ /^package[ \t]/) { }
  else if ($0 ~ /^import[ \t]/) keep(name, "import", $0, rel ":" FNR)
  else keep(name, "body", $0, rel ":" FNR)
  next
}
/^<!-- compile: [a-z]+(-test)? -->$/ {
  name = $3
  if (name != "catalog" && !(name in known)) { err("unknown compile module: " name); next }
  pending = 1; next
}
/<!-- compile/ { err("malformed compile marker") }
END {
  if (pending) err("a compile marker ends the file")
  if (inblock || cat) err("a marked fence is never closed")
  if (catblocks) print "CAT|" rel "|" catblocks
  for (i = 1; i <= names; i++) {
    name = order[i]; mod = name; set = "main"
    if (sub(/-test$/, "", mod)) set = "test"
    unit = units "/" mod "/" set "/" skill "/" base ".kt"; map = maps "/" mod "/" set "/" skill "/" base ".map"
    system("mkdir -p \"" units "/" mod "/" set "/" skill "\" \"" maps "/" mod "/" set "/" skill "\"")
    ln = 0
    for (k = 1; k <= cnt[name SUBSEP "file"]; k++) out(unit, map, txt[name SUBSEP "file" SUBSEP k], org[name SUBSEP "file" SUBSEP k])
    out(unit, map, "package " pkg, "")
    for (k = 1; k <= cnt[name SUBSEP "import"]; k++) out(unit, map, txt[name SUBSEP "import" SUBSEP k], org[name SUBSEP "import" SUBSEP k])
    lists = (set == "test") ? mod " " name : name
    nl = split(lists, list, " ")
    for (j = 1; j <= nl; j++) {
      f = imports "/" list[j] ".imports"; fl = 0
      while ((getline line < f) > 0) {
        fl++
        if (line ~ /^[ \t]*(#|$)/) continue
        if ((name SUBSEP "import " line) in seen) continue
        seen[name SUBSEP "import " line] = 1
        out(unit, map, "import " line, "tests/snippets/" list[j] ".imports:" fl)
      }
      close(f)
    }
    for (k = 1; k <= cnt[name SUBSEP "body"]; k++) out(unit, map, txt[name SUBSEP "body" SUBSEP k], org[name SUBSEP "body" SUBSEP k])
    close(unit); close(map)
    print "UNIT|" unit "|" map "|" rel "|" name "|" blocks[name]
  }
}
function out(unit, map, text, origin) { print text > unit; ln++; print ln "\t" origin > map }'

files=0
for f in "$root"/skills/*/SKILL.md "$root"/skills/*/references/detailed-guide.md; do
  [ -f "$f" ] || continue
  files=$((files + 1))
  rel="${f#"$root"/}"
  skill="${rel#skills/}"; skill="${skill%%/*}"
  case "$rel" in */SKILL.md) base=SKILL ;; *) base=detailed-guide ;; esac
  pkg="snippets.$(printf '%s' "$skill" | tr -- '-' '_').$(printf '%s' "$base" | tr -- '-A-Z' '_a-z')"
  out="$(awk -v rel="$rel" -v skill="$skill" -v base="$base" -v pkg="$pkg" -v units="$units" -v maps="$maps" \
    -v imports="$sandbox" -v catalog="$catalog" "$extract" "$f")"
  printf '%s\n' "$out" | sed -n 's/^ERR|//p' >> "$tmp/errors"
  printf '%s\n' "$out" | sed -n 's/^DRIFT|//p' >> "$tmp/drift"
  printf '%s\n' "$out" | sed -n 's/^UNIT|//p;s/^CAT|\(.*\)|\(.*\)$/CAT|\1|\2/p' >> "$tmp/units.list"
done
[ "$files" -gt 0 ] || die "no skills/*/SKILL.md under $root"

# A prelude is copied beside its unit, in the unit's package; one that serves no unit is an error.
while IFS='|' read -r unit map rel name n; do
  [ "$unit" = CAT ] && continue
  skill="${rel#skills/}"; skill="${skill%%/*}"
  case "$rel" in */SKILL.md) base=SKILL ;; *) base=detailed-guide ;; esac
  prelude="$root/tests/snippets/$skill/$base.$name.kt"
  [ -f "$prelude" ] || continue
  echo "$prelude" >> "$tmp/preludes.used"
  head="$(grep -E '^(package|import) ' "$unit")"
  { printf '%s\n' "$head"; cat "$prelude"; } > "${unit%.kt}.prelude.kt"
  awk -v p="tests/snippets/$skill/$base.$name.kt" -v n="$(printf '%s\n' "$head" | wc -l | tr -d ' ')" \
    'BEGIN { for (i = 1; i <= n; i++) print i "\t" } { print NR + n "\t" p ":" NR }' "$prelude" > "${map%.map}.prelude.map"
done < "$tmp/units.list"
for dir in "$root"/tests/snippets/*/; do
  skill="$(basename "$dir")"
  [ -d "$root/skills/$skill" ] || continue
  for p in "$dir"*; do
    grep -qxF -- "$p" "$tmp/preludes.used" 2>/dev/null || echo "${p#"$root"/}: a prelude no marked unit uses" >> "$tmp/errors"
  done
done
if [ -s "$tmp/errors" ]; then
  { echo "compile-snippets: malformed input, nothing compiled:"; cat "$tmp/errors"; } >&2
  exit 2
fi

units_n=0; blocks=0; failed=0; kotlin=0
while IFS='|' read -r a b c d e f; do
  units_n=$((units_n + 1))
  if [ "$a" = CAT ]; then blocks=$((blocks + c)); else blocks=$((blocks + e)); kotlin=$((kotlin + 1)); fi
done < "$tmp/units.list"

report_catalog() {
  while IFS='|' read -r a rel n rest; do
    [ "$a" = CAT ] || continue
    if grep -qF -- "$rel:" "$tmp/drift"; then
      failed=$((failed + 1)); echo "FAIL $rel (catalog)"; grep -F -- "$rel:" "$tmp/drift" | sed 's/^/  /'
    else
      echo "ok   $rel (catalog), $n block(s)"
    fi
  done < "$tmp/units.list"
}

if [ -n "$emit" ] || [ "$kotlin" -eq 0 ]; then
  report_catalog
  while IFS='|' read -r unit map rel name n; do
    [ "$unit" = CAT ] || echo "unit $rel ($name), $n block(s)"
  done < "$tmp/units.list"
  echo "scanned $files files, $units_n units, $blocks blocks, $failed failed"
  [ "$failed" -eq 0 ]; exit
fi

# The toolchain: an OpenJDK 17+ (GraalVM's jlink cannot build Android's JDK image), and an SDK with platform 37.
jdk="${JAVA_HOME:-}"
if [ -z "$jdk" ]; then
  command -v java >/dev/null 2>&1 || die "no JDK: set JAVA_HOME to an OpenJDK 17 or newer"
  jdk="$(java -XshowSettings:properties -version 2>&1 | sed -n 's/^ *java\.home = //p')"
fi
[ -f "$jdk/release" ] || die "no JDK at '$jdk': set JAVA_HOME to an OpenJDK 17 or newer"
jv="$(sed -n 's/^JAVA_VERSION="\([0-9]*\).*/\1/p' "$jdk/release")"
[ -n "$jv" ] && [ "$jv" -ge 17 ] || die "the JDK at $jdk is ${jv:-unreadable}; the sandbox needs 17 or newer"
! grep -q '^GRAALVM_VERSION=' "$jdk/release" \
  || die "the JDK at $jdk is GraalVM, whose jlink cannot build Android's JDK image: point JAVA_HOME at an OpenJDK"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$sdk" ]; then
  for d in "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do [ -d "$d" ] && { sdk="$d"; break; }; done
fi
[ -n "$sdk" ] && [ -d "$sdk" ] || die "no Android SDK: set ANDROID_HOME"
ls -d "$sdk"/platforms/android-37* >/dev/null 2>&1 \
  || die "the Android SDK at $sdk has no platform 37: sdkmanager \"platforms;android-37.0\""
[ -x "$sandbox/gradlew" ] || die "no Gradle wrapper at $sandbox/gradlew"

tasks_for() {
  case "$1" in
    android)      echo ":android:compileDebugKotlin" ;;
    android-test) echo ":android:compileDebugUnitTestKotlin" ;;
    kmp)          echo ":kmp:compileCommonMainKotlinMetadata :kmp:compileKotlinJvm :kmp:compileAndroidMain" ;;
    kmp-test)     echo ":kmp:compileTestKotlinJvm" ;;
    *-test)       echo ":${1%-test}:compileTestKotlin" ;;
    *)            echo ":$1:compileKotlin" ;;
  esac
}
tasks="$(while IFS='|' read -r unit map rel name n; do [ "$unit" = CAT ] || tasks_for "$name"; done < "$tmp/units.list" \
  | tr ' ' '\n' | sort -u | tr '\n' ' ')"
log="$tmp/gradle.log"
status=0
JAVA_HOME="$jdk" ANDROID_HOME="$sdk" "$sandbox/gradlew" -p "$sandbox" --console=plain --continue \
  -Psnippets.units="$units" $tasks > "$log" 2>&1 || status=$?

# Each `e:` line naming a unit or prelude line becomes <markdown file>:<line>; the rest is the sandbox's own.
find "$maps" -name '*.map' | while IFS= read -r m; do
  r="${m#"$maps"/}"; src="$units/${r%.map}.kt"
  awk -v src="$src" -F'\t' '{ print src ":" $1 "\t" $2 }' "$m"
done > "$tmp/lines"
awk -F'\t' -v units="$units/" '
  NR == FNR { at[$1] = $2; next }
  /^e: / {
    line = $0; sub(/^e: (\[ksp\] )?(file:\/\/)?/, "", line)
    if (index(line, units) == 1 && match(line, /\.kt:[0-9]+/)) {
      key = substr(line, 1, RSTART + RLENGTH - 1); rest = substr(line, RSTART + RLENGTH)
      sub(/^:[0-9]+/, "", rest); sub(/^:? */, "", rest)
      if ((key in at) && at[key] != "") { last = "HIT|" key "|"; print last at[key] ": " rest; next }
    }
    last = "MISS|"; print last $0; next
  }
  last != "" && /^[^ \t>*\[]/ && !/^(w|i): |^FAILURE|^BUILD / { print last "  " $0; next }
  { last = "" }' "$tmp/lines" "$log" > "$tmp/hits"
grep '^> Task ' "$log" | grep -vE ' (FAILED|SKIPPED)$' | awk '{ print $3 }' > "$tmp/ran" || true

while IFS='|' read -r unit map rel name n; do
  [ "$unit" = CAT ] && continue
  label="$rel ($name)"
  dir="${unit%.kt}"
  errs="$(grep -F "HIT|$dir." "$tmp/hits" | cut -d'|' -f3- || true)"
  missing=""
  for t in $(tasks_for "$name"); do grep -qxF -- "$t" "$tmp/ran" || missing="$missing $t"; done
  if [ -n "$errs" ]; then
    failed=$((failed + 1)); echo "FAIL $label"; printf '%s\n' "$errs" | sed 's/^/  /'
  elif [ -n "$missing" ]; then
    failed=$((failed + 1)); echo "FAIL $label: not compiled —$missing did not run"
  else
    echo "ok   $label, $n block(s)"
  fi
done < "$tmp/units.list"
report_catalog
if grep -q '^MISS|' "$tmp/hits"; then
  echo "errors outside the marked blocks:"; sed -n 's/^MISS|/  /p' "$tmp/hits"
fi
echo "scanned $files files, $units_n units, $blocks blocks, $failed failed"
if [ "$status" -ne 0 ] && ! grep -q '^HIT|' "$tmp/hits"; then
  { echo "compile-snippets: Gradle failed before any marked block could be blamed:"; tail -40 "$log"; } >&2
  exit 2
fi
[ "$failed" -eq 0 ]
