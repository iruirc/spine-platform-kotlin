#!/usr/bin/env bats
# In Codex CLI's workspace-write sandbox Gradle cannot write ~/.gradle or reach the network, and adb
# cannot reach its server on localhost:5037, so every build, test run and device call would stop to
# ask (multi-llm milestone 7). setup copies these rules into the project.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  RULES="$ROOT/runtimes/codex-cli/rules/kotlin.rules"
}

decision() { codex execpolicy check --resolve-host-executables --rules "$RULES" "$@"; }

@test "the rules let gradlew, adb and emulator out of the sandbox and nothing else" {
  command -v codex >/dev/null || skip "codex is not installed"
  [ -f "$RULES" ] || { echo "no $RULES"; false; }
  for cmd in "./gradlew :app:testDebugUnitTest" "gradlew --version" \
             "$HOME/Library/Android/sdk/platform-tools/adb devices" "adb shell am start -n a/.B" \
             "emulator -avd Medium_Phone" "emulator -list-avds"; do
    run decision $cmd
    [[ "$output" == *'"decision":"allow"'* ]] || { echo "$cmd: $output"; false; }
  done
  for cmd in "gradle build" "java -version" "sdkmanager --list" "avdmanager list avd"; do
    run decision $cmd
    [[ "$output" == *'"matchedRules":[]'* ]] || { echo "$cmd: $output"; false; }
  done
}

@test "the rules say who writes them and the risk they take" {
  [ -f "$RULES" ] || { echo "no $RULES"; false; }
  for s in 'setup' 'delete' 'build logic' 'adb shell'; do
    grep -qiF -- "$s" "$RULES" || { echo "header lacks: $s"; false; }
  done
}
