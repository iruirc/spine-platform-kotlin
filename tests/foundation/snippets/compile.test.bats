#!/usr/bin/env bats
# The marked blocks compile in the Gradle sandbox: minutes, not seconds, so `scripts/test-foundation.sh all`
# leaves this suite out and `scripts/test-foundation.sh snippets` runs it.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SNIP="$ROOT/scripts/compile-snippets.sh"
  FX="$ROOT/tests/foundation/fixtures/snippets"
}

@test "a block for every module and test source set compiles, with its prelude and default imports" {
  run "$SNIP" "$FX/compiles"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qxF 'scanned 3 files, 14 units, 15 blocks, 0 failed' <<<"$output" || { echo "$output"; return 1; }
}

@test "a block that does not compile fails at its Markdown line, and what depends on it is not passed" {
  run "$SNIP" "$FX/fails"
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  grep -qF "skills/demo/SKILL.md:5: Initializer type mismatch" <<<"$output" || { echo "$output"; return 1; }
  grep -qF 'FAIL skills/demo/SKILL.md (jvm-test): not compiled' <<<"$output" || { echo "$output"; return 1; }
  grep -qF 'tests/snippets/demo/detailed-guide.ktor.kt:2:' <<<"$output" || { echo "a prelude error is not mapped: $output"; return 1; }
  grep -qxF 'scanned 2 files, 3 units, 3 blocks, 3 failed' <<<"$output" || { echo "$output"; return 1; }
}

@test "every marked block in the plugin compiles" {
  run "$SNIP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  n="$(ls "$ROOT"/skills/*/SKILL.md "$ROOT"/skills/*/references/detailed-guide.md | wc -l | tr -d ' ')"
  grep -qE "^scanned $n files, [0-9]+ units, [0-9]+ blocks, 0 failed$" <<<"$output" || { echo "want $n files scanned: $output"; return 1; }
}

@test "a declaration removed since the last build does not resolve in the next one" {
  r="$BATS_TEST_TMPDIR/root"
  mkdir -p "$r/skills/stale" "$r/tests/snippets/stale"
  printf '%s\n' '# Stale' '' '<!-- compile: jvm -->' '```kotlin' 'val answer = stub()' '```' > "$r/skills/stale/SKILL.md"
  echo 'fun stub() = 42' > "$r/tests/snippets/stale/SKILL.jvm.kt"
  run "$SNIP" "$r"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  echo 'fun other() = 0' > "$r/tests/snippets/stale/SKILL.jvm.kt"
  run "$SNIP" "$r"
  [ "$status" -eq 1 ] || { echo "the removed stub still resolved from the last build: $output"; return 1; }
}

@test "a Hilt application compiles in the android module" {
  r="$BATS_TEST_TMPDIR/root"
  mkdir -p "$r/skills/app"
  printf '%s\n' '# App' '' '<!-- compile: android -->' '```kotlin' 'import android.app.Application' \
    'import dagger.hilt.android.HiltAndroidApp' '' '@HiltAndroidApp' 'class DemoApp : Application()' '```' > "$r/skills/app/SKILL.md"
  run "$SNIP" "$r"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a JDK call in a kmp block fails where commonMain is compiled" {
  r="$BATS_TEST_TMPDIR/root"
  mkdir -p "$r/skills/shared"
  printf '%s\n' '# Shared' '' '<!-- compile: kmp -->' '```kotlin' 'fun readConfig(path: String): String = java.io.File(path).readText()' '```' \
    > "$r/skills/shared/SKILL.md"
  run "$SNIP" "$r"
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  grep -qF "skills/shared/SKILL.md:5: Unresolved reference 'java'" <<<"$output" || { echo "$output"; return 1; }
}
