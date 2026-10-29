#!/usr/bin/env bats
# Milestone 7, a project Android Studio built: in a terminal `java` was GraalVM 25, Studio's own JBR
# was 25, and the JDK Studio chose for the project (JBR 21) was only in .gradle/config.properties.
# Agents tried two wrong JDKs before the right one. adb and emulator were not on PATH, and a
# screenshot written with `>` missed Codex's adb rule.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  C="$ROOT/conventions/gradle-toolchain.md"
}

@test "the convention picks the JDK the way Android Studio does" {
  [ -f "$C" ] || { echo "no $C"; return 1; }
  for s in '.gradle/config.properties' 'java.home' 'JAVA_HOME' '-Dorg.gradle.java.home=' 'GRAALVM_VERSION'; do
    grep -qF -- "$s" "$C" || { echo "convention lacks: $s"; return 1; }
  done
}

@test "the convention finds adb and the emulator outside PATH and screenshots without a redirect" {
  [ -f "$C" ] || { echo "no $C"; return 1; }
  for s in 'ANDROID_HOME' 'sdk.dir' 'local.properties' 'Library/Android/sdk' 'adb pull'; do
    grep -qF -- "$s" "$C" || { echo "convention lacks: $s"; return 1; }
  done
}

@test "every agent that builds, tests or drives the project points at the convention" {
  for f in $(grep -lE 'gradlew|\badb\b' "$ROOT"/agents/*.md) "$ROOT"/agents/*-developer.md "$ROOT"/agents/*-tester.md \
           "$ROOT"/agents/*-validator.md "$ROOT"/agents/kotlin-refactorer.md "$ROOT"/agents/kotlin-diagnostics.md; do
    grep -qF 'conventions/gradle-toolchain.md' "$f" || { echo "$(basename "$f"): no pointer"; return 1; }
  done
}

# Milestone 7: Espresso 3.6.1 cannot run on an API 37 image; the developer agent downloaded an API 35
# system image on its own and spent an hour of Execute. Upgrading Espresso was never offered.
@test "the convention stops at a failure the environment causes instead of installing around it" {
  for s in 'system image' 'dependency' 'options'; do
    grep -qF -- "$s" "$C" || { echo "convention lacks: $s"; return 1; }
  done
}
