---
name: release-ops
description: "Use when a spine-toolkit methodology skill resolves topic release ops for a Kotlin project and the concern is shared by every target — versioning and version codes, CI lanes (build, test, lint, release), crash and error reporting choice, feature flags and kill switches, secrets in CI, and Compose Desktop distribution (jpackage, Conveyor, signing and notarization per OS). Routes Android-only and server-only concerns to release-ops-android and release-ops-server."
---

# Release Ops

The Kotlin answers behind spine-toolkit's **release ops** topic, for the half of it that is the same
whichever surface the build produces: where a version number comes from, which lanes CI runs, where
a crash lands, what a kill switch actually buys, how a secret reaches Gradle, and how a Compose
Desktop build becomes an installer. The two questions whose answer is a different number per
surface — the release-review calendar buffer and the platform-fragmentation delta — belong to the
sibling that matches the target.

> **Related skills:**
> - `release-ops-android` — the Play review buffer, App Bundles and R8, push, permissions, the fragmentation delta
> - `release-ops-server` — container images, probes, twelve-factor config, shutdown, migrations on deploy, rollout
> - `pkg-gradle-modules` — the module graph the lanes run against, and the caching switches `## CI Lanes` turns on in CI
> - `nav-deeplinks` — the URL scheme a desktop installer has to register, and the signing key behind an App Link
> - `di-composition-root` — where a flag provider, a crash reporter and a config source get bound, once
> - `net-openapi` — the contract check that belongs in a lane, and the versioning a published client follows

## When to Use

- A methodology skill — `spine-toolkit:ops-checklist`, `spine-toolkit:feature-requirements` or
  `spine-toolkit:feature-estimation` — named topic **release ops** and needs a number: a calendar
  buffer, a binary-distribution tier, or whether platform fragmentation applies
- A build has no CI yet, or has lanes nobody can name the order of
- Someone is about to type a version number into a build file
- A crash arrives obfuscated, or does not arrive at all
- User asks "how do we turn this off without a release", "where do the signing secrets live",
  "how do we ship the desktop app", "what do we tag the image with"
- Review finds a secret in `gradle.properties`, a hand-edited `versionCode`, a release build with
  no mapping upload, or a `BuildConfig` boolean called a kill switch

Not for the deploy pipeline itself (`release-ops-server`), not for the store submission
(`release-ops-android`), and not for what the CI lanes are *checking* — the module graph is
`pkg-gradle-modules`, the contract test is `net-openapi`.

## Routing

| The question is about | Ask |
|---|---|
| Play review and its tracks, App Bundles and signing, R8 keep rules, FCM, runtime permissions, Keystore storage, TalkBack | `release-ops-android` |
| Container images, health probes, twelve-factor configuration, graceful shutdown, migrations on deploy, observability, rollout strategy | `release-ops-server` |
| Versioning, CI lanes, crash and error reporting, feature flags, secrets in CI, Compose Desktop packaging | here |

Two of core's keys are answered by whichever of the three matches the target, so route them before
quoting a number:

- **`Release review`** (a calendar buffer, never engineering days) — Play is `release-ops-android`;
  a service is `release-ops-server`; a desktop installer is `## Desktop Distribution` below; a
  library or a CLI has no gate at all, so the buffer is 0 calendar days.
- **`Platform fragmentation`** (applicability, then a value) — `release-ops-android` states when it
  applies and how wide; `release-ops-server` states that it does not.

## Versioning

| Artifact | Version | Derived from |
|---|---|---|
| any published artifact, and the build's `version` | semver `MAJOR.MINOR.PATCH` | the git tag, via `git describe` |
| Android `versionName` | that same semver string | the same tag |
| Android `versionCode` | a monotonic integer | the CI run number, or `git rev-list --count HEAD` — never hand-edited |
| a server image tag | `<semver>-<short sha>` | the tag plus the commit that built it |
| a desktop `packageVersion` | plain `MAJOR.MINOR.PATCH`, no suffix | the semver, stripped |

```kotlin
// build.gradle.kts — computed once, at the root, from git
val describe = providers.exec { commandLine("git", "describe", "--tags", "--always", "--dirty") }
    .standardOutput.asText.get().trim()
val commits = providers.exec { commandLine("git", "rev-list", "--count", "HEAD") }
    .standardOutput.asText.get().trim()

version = (providers.gradleProperty("releaseVersion").orNull ?: describe).removePrefix("v")

android {
    defaultConfig {
        versionName = project.version.toString()
        versionCode = (System.getenv("GITHUB_RUN_NUMBER") ?: commits).toInt()
    }
}
```

1. **One source of truth, and it is git.** A version typed into a build file is a merge conflict on
   every release branch and a number that disagrees with the tag exactly when it matters. The
   `releaseVersion` property above exists so a release lane can pin an exact value; nothing else
   overrides the tag.
2. **`versionCode` is monotonic and machine-derived.** Play refuses a bundle whose `versionCode` is
   not greater than the highest already uploaded on that track, and the number is never shown to a
   user — so it has no business being meaningful. A CI run number is monotonic by construction; the
   commit count is monotonic on a branch that only fast-forwards.
3. **`versionName` is the semver string and nothing else.** It is what the user reads in Settings
   and what the crash reporter groups by; a build metadata suffix there splits one release into two
   groups in the dashboard.
4. **A server image tag carries both the semver and the sha, and is immutable.** That is what makes
   rollback "deploy the previous tag" rather than "rebuild and hope" (`release-ops-server`).
5. **A dirty or untagged build says so.** `git describe --dirty` yields `1.4.2-7-gab12cd-dirty`;
   let it through to the artifact name in every lane except release, so nobody ships a local build
   believing it was 1.4.2.

## CI Lanes

```
lint  →  unit  →  integration  →  assemble  →  release
```

| Lane | Runs | Red means |
|---|---|---|
| lint | `./gradlew detekt lintRelease` (+ `apiCheck` for a published library) | style, a lint error, a broken public API |
| unit | `./gradlew test` | a fast test failed; no device, no container |
| integration | `./gradlew integrationTest` — Testcontainers, an in-memory database, a migration chain | a boundary broke |
| assemble | `bundleRelease` / `bootJar` / `packageDistributionForCurrentOS` | the release configuration does not build |
| release | signs, uploads the mapping, pushes the image, publishes | the only lane holding a secret |

```yaml
# .github/workflows/ci.yml — the lane, not the whole file
- uses: gradle/actions/setup-gradle@v4
  with:
    cache-read-only: ${{ github.ref != 'refs/heads/main' }}
- run: ./gradlew detekt lintRelease
- run: ./gradlew test
- run: ./gradlew integrationTest
- run: ./gradlew bundleRelease --scan
```

1. **A lane is one Gradle invocation, and `check` comes before `assemble`.** Gradle deduplicates a
   task graph within a single call, so `./gradlew detekt test` in one invocation is cheaper than two
   — split a lane into its own job to buy parallelism or an isolated environment, not by reflex.
2. **Cache Gradle in CI or pay for a cold build every time.** `gradle/actions/setup-gradle` (or
   `actions/cache` over the Gradle user home, keyed by the version catalog and the lockfiles) plus
   the build cache and the configuration cache — the same switches `pkg-gradle-modules`
   `## Build Performance` sets locally, with the remote build-cache node pointed at CI.
3. **Fail fast across lanes, complete within one.** Nothing runs after a red lane; but `--continue`
   inside a lane turns twelve reruns into one report of every failing module.
4. **`--scan` on the lane that fails.** A build scan names the slow task and the cache miss; without
   one, a CI-only failure is debugged by pushing commits.
5. **The release lane is the only one with credentials**, which is what lets every other lane run on
   a pull request from a fork (`## Secrets in CI`).
6. **The release build gets assembled on every push, not on release day.** R8, resource shrinking
   and the signing config only run in the release configuration; a lane that never builds it finds
   out what it strips at the worst moment (`release-ops-android` `## Binary`).

## Crash and Error Reporting

| Surface | Pick one | Because |
|---|---|---|
| Android or Compose Desktop app | Firebase Crashlytics, Sentry, or Bugsnag | native and JVM crash grouping, plus a crash-free rate per release — the number a staged rollout is halted on |
| JVM server | Sentry, or OpenTelemetry into the platform's own error tracker | an error already correlated with the trace and the request id it came from (`release-ops-server` `## Observability`) |

1. **One reporter per surface.** Two SDKs both installing an uncaught-exception handler produce two
   partial truths and one argument about which dashboard is right.
2. **The mapping file is uploaded by the release lane, automatically.** The Crashlytics Gradle
   plugin and `sentry-android-gradle-plugin` both hook `assembleRelease`/`bundleRelease` and upload
   R8's `mapping.txt`; a manual upload is a step someone skips. Add the NDK symbols too if the app
   ships a native library.
3. **A build shipped without its mapping is a build with no crash reports** — the frames are
   `a.b.c`, the grouping is nonsense, and it cannot be fixed after the fact for builds already in
   the field.
4. **Send bugs, not outcomes.** A handled, expected failure is a log line; what belongs in the
   reporter is the unmapped and the unexpected. The taxonomy is `error-architecture`.
5. **No PII in breadcrumbs, user properties or the message** — a crash reporter is a third party
   (`error-architecture` `## Logging and PII`).
6. **Bind it at the composition root, behind an interface** (`di-composition-root`), so tests and
   debug builds get a no-op and no layer below the root imports the vendor.

## Feature Flags

| Kind | Take | Kill switch? |
|---|---|---|
| remote config | Firebase Remote Config, LaunchDarkly, Unleash, or a JSON endpoint the backend already serves | yes — the off state reaches a user who installed nothing |
| in-app build flag | a `buildConfigField` per build type, or a Gradle property read at configuration time | no — it is compile-time; changing it is a release |

**`Binary distribution risk` — the platform's answer to core's key, by rollback path:**
**0%** for a server, a CLI or a library (no user holds the binary; rollback is a redeploy);
**+10%** when the feature sits behind a remote flag whose off state reaches users without a new
build — the kill switch is a fixed +10% delta per `spine-toolkit:feature-estimation`'s
binary-distribution tier; **+20%** for a user-facing app binary with no instant rollback. Pick one
tier and apply the same value in the best and the worst scenario.

1. **A kill switch is a flag whose default is *on* and whose remote *off* is honoured within one app
   start.** Not one release later, not after a cache TTL nobody measured. A flag that needs a store
   release to turn off is not a kill switch and does not earn the +10% tier.
2. **Fetch before the first read, and ship a safe default.** The first launch is offline more often
   than anyone plans for; the compiled-in default is the value that ships to those users.
3. **Flags are read at the composition root, not at the call site** (`di-composition-root`). One
   provider means one list of the flags that exist, one place to override them in a test, and no
   feature module importing the vendor SDK.
4. **Every flag gets an owner and a removal date.** A flag past its rollout is an untested branch
   that will be executed by somebody, eventually, in production.
5. **A flag does not un-migrate a database.** Turning off a feature whose migration already ran
   leaves the schema changed; that path is `persistence-migrations`, not a switch.

## Secrets in CI

The chain is **CI secret store → environment variable → a `-P` Gradle property or `System.getenv`
in the build script**. Nothing else, and nothing committed.

```kotlin
// build.gradle.kts — the secret is read in exactly one place
val keystorePassword: String? = System.getenv("KEYSTORE_PASSWORD")
    ?: providers.gradleProperty("keystorePassword").orNull
```

```yaml
- run: echo "$KEYSTORE_BASE64" | base64 --decode > "$RUNNER_TEMP/upload.jks"
  env: { KEYSTORE_BASE64: "${{ secrets.KEYSTORE_BASE64 }}" }
- run: ./gradlew bundleRelease
  env:
    KEYSTORE_PATH: "${{ runner.temp }}/upload.jks"
    KEYSTORE_PASSWORD: "${{ secrets.KEYSTORE_PASSWORD }}"
```

1. **Never a secret in a committed `gradle.properties`, and never in `local.properties`.**
   `local.properties` is kept out of git by a convention and by nothing enforcing it; the first
   person to commit it publishes the key to everyone who ever clones the repo.
2. **A binary secret travels as base64.** The signing keystore, `google-services.json`, a
   service-account JSON: one CI secret each, decoded into the runner's temp directory inside the
   lane, never into the working tree where a later step can archive it.
3. **Read it once.** A password reached for in three build files is a password printed by whichever
   of them someone adds a `println` to.
4. **Print nothing.** `--info` and `--debug` dump properties; a task that echoes its own
   configuration echoes the password with it. Keep secrets out of Gradle properties whose name the
   log prints, and rely on the CI masker as a second line, not the first.
5. **A leaked secret is rotated, not deleted.** Rewriting history does not un-publish what a fork,
   a mirror or a cache already has: revoke the key, issue a new one, then clean up.

## Desktop Distribution

```kotlin
// build.gradle.kts
compose.desktop {
    application {
        mainClass = "com.example.MainKt"
        nativeDistributions {
            targetFormats(TargetFormat.Dmg, TargetFormat.Msi, TargetFormat.Deb)
            packageName = "ExampleApp"
            packageVersion = "1.4.2"   // plain MAJOR.MINOR.PATCH — see rule 2
        }
    }
}
```

`./gradlew packageDistributionForCurrentOS` runs `jpackage` under the hood.

1. **One OS per runner.** `jpackage` builds only for the host it runs on: a `.dmg` needs a macOS
   runner, an `.msi` a Windows one, a `.deb` a Linux one. That is three jobs in the release lane
   producing one artifact each, not one job producing three.
2. **`packageVersion` is not `git describe` output.** `jpackage` demands a plain
   `MAJOR.MINOR.PATCH` (and on macOS a major component of at least 1); `1.4.2-7-gab12cd` fails
   packaging late, after the build. Derive it from the semver with the suffix stripped
   (`## Versioning`).
3. **Conveyor when the app must update itself.** Hydraulic Conveyor packages every OS from one
   machine and gives the app an auto-update channel; `jpackage` gives neither. Take it when there is
   no Windows or macOS runner to hand, or when shipping a second version to installed users has to
   be something other than "email them a link".
4. **Signing is per OS, and the first time is calendar work.** macOS: `codesign` with a Developer ID
   certificate, then notarization through `notarytool` and a stapled ticket. Windows: Authenticode,
   which for a new certificate now means an HSM or a cloud signing service.

   **`Release review` — the platform's answer to core's key for a directly distributed desktop
   app:** no store review, so 0 calendar days of review, but budget **calendar +1–2 days first
   time** for signing and notarization — obtaining the certificates, getting the entitlements
   right, and the first notarization that comes back rejected. Later releases cost minutes.
5. **A store puts the gate back.** Shipping through the Mac App Store or the Microsoft Store
   re-introduces a review with that store's own calendar and its own rules; direct download, or
   Conveyor's own channel, has none.
6. **URL-scheme registration happens at packaging time, and `jpackage` has no option for it.** The
   scheme is an `Info.plist` key on macOS, a registry key on Windows, a `.desktop` file with a
   `MimeType` line on Linux — see `Desktop Scheme Registration` in
   `skills/nav-deeplinks/references/detailed-guide.md` before promising a desktop deep link, because
   the answer constrains which packager the build can use.
7. **Unsigned means a warning the user has to click past** — Gatekeeper quarantine on macOS,
   SmartScreen on Windows. For an internal tool that may be acceptable; decide it, rather than
   discovering it from the first support ticket.

## Common Mistakes

1. **A hand-edited `versionCode`.** It conflicts on every release branch, goes backwards exactly
   once, and the upload that rejects it is the one under time pressure.
2. **A release build with no mapping upload.** The crash reports arrive obfuscated and cannot be
   symbolicated afterwards for builds already installed — the mapping for that build no longer
   exists anywhere.
3. **A `BuildConfig` boolean called a kill switch.** It cannot be turned off without shipping a new
   binary, so the feature carries the no-rollback tier, not the flag tier — and the estimate that
   claimed +10% was wrong by a whole rollback path.
4. **Secrets in `gradle.properties` or `local.properties`.** Committed once, public forever; the fix
   is rotation, and the rotation is a release.
5. **Every lane in one `./gradlew build`.** One red line hides the other four, the slow integration
   suite runs before the lint that would have failed in eight seconds, and nothing is cached
   because the job never repeats.
6. **CI with no Gradle cache.** Every push pays a cold configuration and a full compile; the team
   concludes the build is slow and starts skipping the lane.
7. **Two crash reporters, installed by two SDKs nobody chose together.** The second handler either
   never fires or swallows what the first would have reported.
8. **`packageVersion` taken from `git describe`.** The desktop packaging step fails on the suffix,
   in the release lane, on the day of the release.
9. **A flag with no expiry.** Two years later the code has four live combinations, tests cover one,
   and no one dares delete any of them.
