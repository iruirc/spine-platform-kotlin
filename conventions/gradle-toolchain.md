# Gradle toolchain: the JDK, the Android SDK, the device

The project builds in the IDE; a terminal is not the IDE. Android Studio and IntelliJ keep the JDK
they chose for the project in their own files, and the SDK tools are seldom on `PATH`. Every agent
that runs `./gradlew`, `adb` or `emulator` finds them the way the IDE does, before its first call —
not after a failed build.

## The JDK

The first that exists wins:

1. `java.home` in `.gradle/config.properties` at the project root — the JDK the IDE chose for this
   project (Android Studio writes it when the Gradle JDK is set to `GRADLE_LOCAL_JAVA_HOME`).
2. `org.gradle.java.home` in the project's `gradle.properties` — Gradle reads it by itself; pass
   nothing.
3. `JAVA_HOME` of the environment.
4. `java` on `PATH`.

A JDK whose `release` file carries `GRAALVM_VERSION` cannot build an Android project — its `jlink`
cannot build Android's JDK image. Skip it and take the next one; with none left, say so as the
step's cause.

Pass the JDK on the command line, so the command still starts with `gradlew`:

```
./gradlew -Dorg.gradle.java.home=<jdk> <tasks>
```

In Codex CLI a wrapped call — `long-run.sh start -- ./gradlew -Dorg.gradle.java.home=<jdk> <tasks>` —
works the same. Never prefix the command with `JAVA_HOME=…` or `env`: Codex's rules then see `env`,
not `gradlew` (`runtimes/codex-cli.md` of spine-toolkit, "Builds and the simulator").

Name the JDK and where it came from in the step's log section, once.

## The Android SDK

`adb` is `<sdk>/platform-tools/adb`, `emulator` is `<sdk>/emulator/emulator`. The first that exists
wins:

1. `ANDROID_HOME`, then `ANDROID_SDK_ROOT`.
2. `sdk.dir` in `local.properties` at the project root — the IDE writes it.
3. `~/Library/Android/sdk` (macOS), `~/Android/Sdk` (Linux).
4. `adb` and `emulator` on `PATH`.

Call them by full path. None found: a step that needs a device cannot run — the validator's rules
say whether that is FAILED or deferred.

## A screenshot

```
adb -s <serial> shell screencap -p /sdcard/spine-shot.png
adb -s <serial> pull /sdcard/spine-shot.png <path>.png
```

Two calls — `screencap` on the device, then `adb pull` — and no redirect: `adb exec-out screencap -p > <file>` writes the same file, but a command with
`>` is matched by no Codex rule and stops to ask.

## A failure the environment causes

A test that fails before it reaches its own assertions, and fails the same way without your change —
a test library that cannot run on the device's API level, a JDK the build refuses, a tool missing
from the SDK — is the environment's failure, not the change's. Do not install your way around it:
no SDK platform, system image or JDK downloaded, no dependency version raised, no device created.
Each of those changes the user's machine or the project beyond the task. Stop the step, and return
the failure — the first error line and the test it stopped — with the options you see, for example:

- another device or API level the user already has;
- raising the dependency that does not support this one, as a task of its own;
- a check by hand.

The user picks; you continue with what they picked.
