#!/usr/bin/env bats
# The platform half of core's device setting (spine-toolkit conventions/stage-dispatch.md → Device):
# the device a brief names outranks the first one adb lists and the project's files, for every
# agent that builds or tests on one, and the ui validator knows how to hand it to adb and Gradle.

setup() {
  ROOT="$(cd -- "$(dirname -- "$BATS_TEST_FILENAME")/../../.." && pwd)"
  V="$ROOT/agents/kotlin-ui-validator.md"
}

@test "the emulator lane takes the brief's device, below the owner's directive" {
  x="$(sed -n '/^### Emulator lane (Android)$/,/^### /p' "$V")"
  for f in "The brief's Device line wins over the first one listed as well, but not over a device the owner's directive names" \
    'goes into `ANDROID_SERIAL`' 'any other value is an AVD name' '`connectedDebugAndroidTest` runs on it too'; do
    grep -qF -- "$f" <<<"$x" || { echo "step 4 lost: $f"; return 1; }
  done
}

@test "the ui validator drives the device the brief names" {
  x="$(sed -n '/^### Emulator lane (Android)$/,/^### /p' "$V")"
  grep -qF "The target the driver selects is the device step 4 settled" <<<"$x" \
    || { echo "step 7 lost the device rule"; return 1; }
}

@test "every agent that builds or tests on a device puts the brief's device above its project files" {
  for a in compose-developer kmp-developer diagnostics refactorer ui-tester kmp-tester; do
    f="$ROOT/agents/kotlin-$a.md"
    sed -n '12p' "$f" | grep -qF "A device the brief's Device line names outranks any these files name." \
      || { echo "kotlin-$a: First line lost the device rule"; return 1; }
  done
}
