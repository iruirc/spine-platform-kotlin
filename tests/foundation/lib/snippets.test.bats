#!/usr/bin/env bats
# What scripts/compile-snippets.sh does before Gradle: markers, units, preludes, the catalog, the toolchain.
# The Gradle build itself runs in tests/foundation/snippets, through `scripts/test-foundation.sh snippets`.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SNIP="$ROOT/scripts/compile-snippets.sh"
  FX="$ROOT/tests/foundation/fixtures/snippets"
  SANDBOX="$ROOT/tests/snippets"
  OUT="$BATS_TEST_TMPDIR/units"
}

@test "the version catalog pins the majors the skills teach" {
  c="$SANDBOX/gradle/libs.versions.toml"
  for want in 'kotlin = "2\.4\.' 'agp = "9\.' 'spring-boot = "4\.' 'exposed = "1\.' 'testcontainers = "2\.' \
              'koin = "4\.2\.' 'orbit = "12\.' 'room = "2\.' 'junit-jupiter = "5\.' 'navigation3 = "1\.'; do
    grep -qE "^$want" "$c" || { echo "the catalog does not pin $want"; return 1; }
  done
  ! grep -qE '^room3' "$c" || { echo "Room 3 is a variant, not the pinned major"; return 1; }
}

fake_jdk() {
  mkdir -p "$BATS_TEST_TMPDIR/jdk"
  printf 'JAVA_VERSION="%s"\n' "$1" > "$BATS_TEST_TMPDIR/jdk/release"
  [ -z "${2:-}" ] || echo "$2" >> "$BATS_TEST_TMPDIR/jdk/release"
}

@test "a file's blocks of one marker form one unit, in file order, with imports hoisted" {
  run "$SNIP" --emit-only "$OUT" "$FX/compiles"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qxF 'scanned 3 files, 14 units, 15 blocks, 0 failed' <<<"$output" || { echo "$output"; return 1; }
  grep -qxF 'unit skills/demo/SKILL.md (jvm), 2 block(s)' <<<"$output" || { echo "$output"; return 1; }
  u="$OUT/jvm/main/demo/SKILL.kt"
  [ "$(sed -n 1p "$u")" = '@file:OptIn(ExperimentalCoroutinesApi::class)' ] || { head -3 "$u"; return 1; }
  [ "$(sed -n 2p "$u")" = 'package snippets.demo.skill' ] || { head -3 "$u"; return 1; }
  [ "$(grep -cxF 'import kotlinx.coroutines.ExperimentalCoroutinesApi' "$u")" -eq 1 ] || { echo "the import was not hoisted once"; return 1; }
  grep -qxF 'import kotlinx.coroutines.flow.*' "$u" || { echo "the module's default imports are missing"; return 1; }
  ! grep -qF 'package com.example.demo' "$u" || { echo "a block's own package line survived"; return 1; }
  [ "$(grep -n 'class Counter(' "$u" | cut -d: -f1)" -lt "$(grep -n 'fun Counter.tickTwice' "$u" | cut -d: -f1)" ] \
    || { echo "blocks are out of file order"; return 1; }
  ! grep -qF 'notMarked' "$u" || { echo "an unmarked block was emitted"; return 1; }
}

@test "a -test marker lands in the test source set with the module's imports and its own" {
  run "$SNIP" --emit-only "$OUT" "$FX/compiles"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  u="$OUT/jvm/test/demo/SKILL.kt"
  [ "$(sed -n 1p "$u")" = 'package snippets.demo.skill' ] || { head -2 "$u"; return 1; }
  grep -qxF 'import kotlinx.coroutines.flow.*' "$u" || { echo "jvm.imports is missing from the test unit"; return 1; }
  grep -qxF 'import org.junit.jupiter.api.*' "$u" || { echo "jvm-test.imports is missing from the test unit"; return 1; }
}

@test "a prelude is emitted beside its unit, in its package, with the unit's imports" {
  run "$SNIP" --emit-only "$OUT" "$FX/compiles"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  p="$OUT/android/main/demo/SKILL.prelude.kt"
  [ -f "$p" ] || { find "$OUT" -name '*.kt'; return 1; }
  [ "$(sed -n 1p "$p")" = 'package snippets.demo.skill' ] || { head -2 "$p"; return 1; }
  grep -qxF 'import androidx.room.*' "$p" || { echo "the prelude lacks the unit's imports"; return 1; }
  grep -qF 'interface NoteDao' "$p" || { echo "the prelude's own text is missing"; return 1; }
  [ ! -e "$OUT/jvm/main/demo/SKILL.prelude.kt" ] || { echo "a prelude reached a unit it does not name"; return 1; }
}

@test "a malformed, misplaced, unknown or trailing marker is an error, not a skip" {
  run "$SNIP" --emit-only "$OUT" "$FX/bad-marker"
  [ "$status" -eq 2 ] || { echo "status $status: $output"; return 1; }
  for want in 'SKILL.md:4: a compile marker must sit directly above a kotlin fence' \
              'SKILL.md:9: malformed compile marker' 'SKILL.md:11: unknown compile module: ios' \
              'SKILL.md:16: a compile marker ends the file'; do
    grep -qF -- "skills/demo/$want" <<<"$output" || { echo "missing: $want"; echo "$output"; return 1; }
  done
}

@test "a prelude that serves no marked unit is an error" {
  run "$SNIP" --emit-only "$OUT" "$FX/orphan"
  [ "$status" -eq 2 ] || { echo "status $status: $output"; return 1; }
  grep -qF 'tests/snippets/demo/SKILL.android.kt: a prelude no marked unit uses' <<<"$output" || { echo "$output"; return 1; }
  ! grep -qF 'SKILL.jvm.kt' <<<"$output" || { echo "a used prelude was reported: $output"; return 1; }
}

@test "a marked TOML line the version catalog does not hold fails at its line" {
  run "$SNIP" "$FX/drift"
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  grep -qF 'skills/demo/SKILL.md:7: not in [versions] of tests/snippets/gradle/libs.versions.toml: agp = "8.13.0"' <<<"$output" \
    || { echo "$output"; return 1; }
  ! grep -qF 'SKILL.md:6:' <<<"$output" || { echo "a line the catalog holds was reported"; return 1; }
  grep -qxF 'scanned 1 files, 1 units, 1 blocks, 1 failed' <<<"$output" || { echo "$output"; return 1; }
}

@test "a JDK older than 17, or GraalVM, is refused before Gradle" {
  fake_jdk 11.0.2
  run env JAVA_HOME="$BATS_TEST_TMPDIR/jdk" "$SNIP" "$FX/fails"
  [ "$status" -eq 2 ] && grep -qF 'is 11; the sandbox needs 17 or newer' <<<"$output" || { echo "status $status: $output"; return 1; }
  fake_jdk 25.0.1 'GRAALVM_VERSION="25.0.1"'
  run env JAVA_HOME="$BATS_TEST_TMPDIR/jdk" "$SNIP" "$FX/fails"
  [ "$status" -eq 2 ] && grep -qF 'is GraalVM' <<<"$output" || { echo "status $status: $output"; return 1; }
}

@test "an Android SDK without platform 37 is refused, and the platform named" {
  fake_jdk 21.0.4
  mkdir -p "$BATS_TEST_TMPDIR/sdk/platforms/android-36"
  run env JAVA_HOME="$BATS_TEST_TMPDIR/jdk" ANDROID_HOME="$BATS_TEST_TMPDIR/sdk" "$SNIP" "$FX/fails"
  [ "$status" -eq 2 ] || { echo "status $status: $output"; return 1; }
  grep -qF 'has no platform 37: sdkmanager "platforms;android-37.0"' <<<"$output" || { echo "$output"; return 1; }
}

@test "a root without skills, or a non-empty --emit-only directory, is an error" {
  run "$SNIP" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 2 ] && grep -qF 'no skills/*/SKILL.md' <<<"$output" || { echo "status $status: $output"; return 1; }
  mkdir -p "$OUT"; touch "$OUT/stale.kt"
  run "$SNIP" --emit-only "$OUT" "$FX/compiles"
  [ "$status" -eq 2 ] && grep -qF 'is not empty' <<<"$output" || { echo "status $status: $output"; return 1; }
}

@test "the sandbox builds the modules the script knows, and each has its imports" {
  settings="$(grep -oE '":[a-z]+"' "$SANDBOX/settings.gradle.kts" | tr -d '":' | sort | tr '\n' ' ')"
  script="$(grep -oE 'split\("[a-z ]+", m' "$SNIP" | sed 's/split("//; s/", m//' | tr ' ' '\n' | sort | tr '\n' ' ')"
  [ "$settings" = 'android jvm kmp ktor net spring ' ] || { echo "settings: $settings"; return 1; }
  [ "$settings" = "$script" ] || { echo "settings: $settings; script: $script"; return 1; }
  for m in $settings; do
    [ -f "$SANDBOX/$m/build.gradle.kts" ] || { echo "no build script for $m"; return 1; }
    [ -s "$SANDBOX/$m.imports" ] && [ -s "$SANDBOX/$m-test.imports" ] || { echo "no imports for $m"; return 1; }
    grep -qF '"snippets.units"' "$SANDBOX/$m/build.gradle.kts" || { echo "$m does not take the emitted units"; return 1; }
  done
}

@test "every marked block in the plugin parses, and every skill file is scanned" {
  run "$SNIP" --emit-only "$OUT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  n="$(ls "$ROOT"/skills/*/SKILL.md "$ROOT"/skills/*/references/detailed-guide.md | wc -l | tr -d ' ')"
  grep -qE "^scanned $n files, " <<<"$output" || { echo "want $n files scanned: $output"; return 1; }
}
