---
name: gradle-toolchain
description: "Use when a step is about to make its first ./gradlew, adb or emulator call in a project that builds in Android Studio or IntelliJ: which JDK to pass to Gradle (the one the IDE chose for the project, never GraalVM), where adb and the emulator are when they are not on PATH, how to take a screenshot with no shell redirect, and what to do when a test fails because of the environment rather than the change — stop and offer options, never install around it."
---

# Gradle Toolchain

The project builds in the IDE; a terminal is not the IDE. Android Studio and IntelliJ keep the JDK
they chose for the project in their own files, and the SDK tools are seldom on `PATH`. Every agent
that runs `./gradlew`, `adb` or `emulator` finds them the way the IDE does, before its first call —
not after a failed build.

> **Related skills:**
> - `test-frameworks` — what a test needs from the build to run at all
> - `release-ops-android` — the SDK and signing setup a release build needs

## When to Use

- Before the first `./gradlew`, `adb` or `emulator` call of a step.
- When Gradle stops before compiling with only a Java version in "What went wrong".
- When a test fails before its own assertions on one device or JDK and not on another.

## The JDK

The first that exists wins:

1. `java.home` in `.gradle/config.properties` at the project root — the JDK the IDE chose for this
   project (Android Studio writes it when the Gradle JDK is set to `GRADLE_LOCAL_JAVA_HOME`).
2. `org.gradle.java.home` in the project's `gradle.properties` — Gradle reads it by itself; pass
   nothing.
3. `JAVA_HOME` of the environment.
4. On macOS, `/usr/libexec/java_home -V`: it lists every installed JDK with its home — take the
   newest the build accepts. `java` on `PATH` is a stub there and gives no home to pass.
5. Elsewhere, `java` on `PATH`: its home is two levels above the resolved binary.

For an Android build, a JDK whose `release` file carries `GRAALVM_VERSION` is skipped: its `jlink`
cannot build Android's JDK image. Name each skipped JDK and why in the step's log; with none left,
the cause is "only GraalVM found (<paths>) — set the project's Gradle JDK in the IDE". A server's
native build needs GraalVM and keeps it.

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

A test that fails before it reaches its own assertions — a test library that cannot run on the
device's API level, a JDK the build refuses, a tool missing from the SDK — is the environment's
failure, not the change's. Do not install your way around it: no SDK platform, system image or JDK
downloaded, no dependency version raised, no device created. Each of those changes the user's machine
or the project beyond the task. Stop the step and name the failure — its first error line and the
test it stopped — with the options you see, for example:

- another device or API level the user already has;
- raising the dependency that does not support this one, as a task of its own;
- a check by hand.

Where they go depends on who stops:

- **A validator** writes `FAILED` with the cause `environment: <first error line>` and puts the
  options in its return digest; the user picks between stages.
- **An implementing stage** (developer, tester, refactorer) stops before committing the step and puts
  the failure and the options in its stage report.

## Common Mistakes

| Mistake | Consequence | Instead |
|---|---|---|
| `./gradlew` with whatever `java` is on `PATH` | GraalVM or a newer JDK than the Gradle wrapper supports; the build stops at "What went wrong: 25.0.x" | the JDK in `.gradle/config.properties`, passed as `-Dorg.gradle.java.home=` |
| The JDK bundled with the IDE (`…/Android Studio.app/Contents/jbr`) | it is the IDE's own runtime, not the project's choice, and may be too new | the project's `java.home` |
| `JAVA_HOME=… ./gradlew` or `env JAVA_HOME=…` | Codex matches `env`, not `gradlew`: every build stops to ask | `-Dorg.gradle.java.home=` on the command line |
| `adb exec-out screencap -p > file` | the redirect is matched by no rule | `screencap` on the device, then `adb pull` |
| Downloading a system image to get past a test library that does not support the device | gigabytes on the user's machine and an hour of the step, no choice offered | stop with the options |
