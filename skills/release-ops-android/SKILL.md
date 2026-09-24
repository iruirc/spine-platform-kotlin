---
name: release-ops-android
description: "Use when resolving release ops for an Android app — Play Console review and its calendar buffer, App Bundles and signing, R8/ProGuard keep rules, FCM push token handling, runtime permissions, OS-version and device fragmentation delta, TalkBack and touch-target accessibility, and Play policy constraints."
---

# Release Ops — Android

The Android half of spine-toolkit's **release ops** topic: what "distribution-channel review",
"platform fragmentation", "push-provider token", "secure storage" and "assistive-technology labels"
actually cost when the target is an app on Play. Everything a Kotlin build shares with the other
targets — versioning, CI lanes, crash reporting, feature flags, secrets — is `release-ops`.

> **Related skills:**
> - `release-ops` — versioning, CI lanes, the crash reporter this skill uploads a mapping to, and the flag tiers behind the rollback path
> - `persistence-architecture` — the Keystore-backed store this skill points at rather than restating
> - `net-http-clients` — the OkHttp client the pin and the timeouts are configured on
> - `nav-deeplinks` — the App Link the signing key proves, and the route a notification opens
> - `concurrency-coroutines` — the background-execution limits a fragmented OEM matrix enforces, and WorkManager
> - `compose-state` — the four permission states a screen has to render, and where they live

## When to Use

- `spine-toolkit:feature-estimation` needs the Play review buffer or a verdict on the
  fragmentation delta, or `spine-toolkit:ops-checklist` has a **Release ops** row to settle
- `spine-toolkit:feature-requirements` listed push, permissions or accessibility as a secondary
  requirement and nobody has priced it
- A release is being prepared and nobody has said which track it goes to
- Push is being added, or a token stopped arriving at the backend
- A release build behaves differently from debug — a missing class, an empty screen, a crash on a
  reflective call
- User asks "how long does Play take", "AAB or APK", "what keep rules do we need", "why does
  `onMessageReceived` not fire", "do we need `POST_NOTIFICATIONS`"
- Review finds a token in a preferences store, cleartext allowed in release, an icon button with no
  content description, or a permission requested at launch

Not for the shared build concerns (`release-ops`), not for the URL parser behind a deep link
(`nav-deeplinks`), and not for choosing where local data lives (`persistence-architecture`).

## Distribution-channel review

**`Release review` — the platform's answer to core's calendar-buffer key, for Play:** typically
same-day to 3 days; **+3–7 calendar days** for a first submission, a sensitive permission, or a
policy-adjacent feature; the internal testing track skips it — 0 calendar days. This figure
replaces core's generic `+2–7 calendar days` default for the key — apply one or the other, never
both.

| Track | Review | For |
|---|---|---|
| internal testing | none; live in minutes | dogfooding, a smoke test on real devices, up to 100 testers |
| closed testing | reviewed | a named beta group, and the first place a new permission is seen |
| open testing | reviewed | public beta |
| production | reviewed, then a staged rollout percentage | the release |

1. **Policy-adjacent is a list, not a feeling.** Background location, SMS or Call Log access,
   accessibility services, `QUERY_ALL_PACKAGES`, and any change to the data-safety form each pull in
   a declaration form and often a demo video. That paperwork, not the review queue, is where the
   +3–7 calendar days go.
2. **A brand-new personal developer account owes a closed test first.** Before its first production
   release Play requires a closed test running at least 14 continuous days with at least 12 testers
   opted in — a 14-calendar-day buffer landing on exactly the first-submission case, on top of the
   review itself. An organisation account does not owe it.
3. **The pre-launch report is free device-matrix coverage.** Promoting to a testing track runs the
   app on real devices and returns crashes, accessibility findings and security warnings. Read it
   before promoting further; it catches the OEM-specific crash that the team's four phones do not.
4. **A staged rollout can be halted, not reversed.** Android does not downgrade an installed app, so
   the only way back is a new, higher `versionCode` — which is exactly why the rollback path sets
   core's `Binary distribution risk` tier (`release-ops` → "Feature Flags" holds the tiers).
5. **Play App Signing changes what a lost key costs.** The upload key is the team's and is
   replaceable through support; the app signing key is Play's and is not the thing that gets lost.
6. **The data-safety form is part of the release, not of the paperwork afterwards.** A new SDK that
   collects an identifier changes the declaration, and a declaration that disagrees with the binary
   is a takedown risk, not a review delay.

## Platform fragmentation

**`Platform fragmentation` — the platform's answer to core's key, for Android: +20%–30%.** Apply it
when the feature depends on OEM behaviour, background limits, or a permission whose UX changed
across API levels. The project's `- Baseline:` line sets the span — `API 21+` covers far more of the
fragmented matrix than `API 26+` — and the affected baseline is the feature's own: the work items
that touch the fragmented surface, not the whole estimate.

| Fragmented | What varies | Cost |
|---|---|---|
| OEM background policy | aggressive task killers and battery managers (several large vendors) stop work the framework says is allowed | work that is never observed to fail in the office |
| background execution limits | Doze and App Standby buckets, foreground-service types on 14+, exact alarms on 12+ | per-API-level branches in scheduling (`concurrency-coroutines`) |
| permission UX | `POST_NOTIFICATIONS` on 13+, granular media on 13+, background location split on 10+, scoped storage | a different flow per API level, each needing its own screen states |
| display and input | screen sizes, foldables, font scale, gesture vs button navigation | layout and accessibility work that only shows up on a device you do not own |
| system WebView and vendor forks | rendering and JS behaviour differ by WebView version | reproducing a bug requires the exact device |

1. **Skip the delta for a feature that never leaves your own process.** Compose UI over a repository,
   on `API 24+`, with no permission and no background work, is not fragmented — applying the delta
   there inflates every estimate and teaches the team to ignore it.
2. **Apply it once, scoped.** Name the work items it covers in the estimate; a delta on the whole
   baseline for one background-sync item is the double-count core warns about.
3. **Emulators do not settle OEM questions.** The delta buys real devices, or a device-farm run of
   the pre-launch report — budget the hours, not just the risk.

## Push transport

- **FCM is the transport** (`com.google.firebase:firebase-messaging`). There is no second one to
  choose or abstract over.
- **Token rotation is normal**, not an error path: a reinstall, cleared app data or a restore issues
  a new token. `onNewToken` fires when it rotates *and* the delivery to your backend can fail — so
  also read the current token on every cold launch and upsert it.
- **A notification that opens a screen is a deep link** — the route parsing is `nav-deeplinks`.

| Payload | App in foreground | App backgrounded or killed |
|---|---|---|
| `notification` (with or without `data`) | `onMessageReceived` fires | the system tray shows it; `onMessageReceived` never fires, and the `data` reaches you only through the launch `Intent` extras |
| `data` only | `onMessageReceived` fires | `onMessageReceived` fires, but subject to Doze and background limits — `priority: high` for time-sensitive messages, and that budget is metered per app |

```kotlin
class AppMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        // Fire-and-forget here is a lost token: the process may die before the call returns.
        TokenUploadWorker.enqueue(applicationContext, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val route = message.data["route"] ?: return
        notifier.show(route)
    }
}
```

1. **Choose the payload shape deliberately.** A `notification` payload gets free system display and
   loses all control while backgrounded; a `data` payload gives control and makes you responsible
   for posting the notification, the channel, and the case where the OS defers delivery.
2. **Upload the token from work that survives process death** — a WorkManager request, not a
   coroutine launched in the service (`concurrency-coroutines`).
3. **`POST_NOTIFICATIONS` gates everything on 13+.** A perfectly delivered message displays nothing
   until the runtime permission is granted (`## Permissions`).
4. **Deleting the token is part of logout.** A signed-out device that still holds a valid token
   receives the next user's notification.

## Binary

```kotlin
android {
    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName("upload")
        }
    }
}
```

`./gradlew bundleRelease` produces the AAB Play requires; an APK is for a sideload, a CI artifact or
a device farm, and per-ABI splits belong only to that path — the bundle already splits per ABI,
density and language on Play's side.

| Reached by | Keep rules |
|---|---|
| `kotlinx.serialization` generated serializers | none — the compiler rewrites `Foo.serializer()` into a static reference, so R8 keeps it by reachability |
| Moshi or Room with codegen (KSP) | none — the generated adapter is found by name at runtime, and both artifacts ship the consumer rules that keep it |
| Gson, Jackson, or Moshi's reflective adapter | yes: the model classes **and** their fields, or the field names are renamed out from under the parser |
| a class named from a string, a manifest entry, JNI, or a reflective DI lookup | `@Keep`, or an explicit rule in `proguard-rules.pro` |

1. **R8 full mode is the default since AGP 8**, and it is more aggressive than the old one: it
   renames and repackages classes the previous mode left alone. A build that "worked before the
   upgrade" needs its keep rules re-checked, not the mode turned off.
2. **The residual `kotlinx.serialization` trap is the reflective path.** `serializer(typeOf<T>())`
   resolves the serializer by looking the type up at runtime, so a type nothing references
   statically gives R8 no reason to keep it — and the lookup throws in the release build only.
3. **A keep rule is a debt.** Every rule keeps code, names and metadata in the shipped binary;
   `-keep class com.example.** { *; }` is a way of not shrinking at all.
4. **`mapping.txt` goes to the crash reporter from the release lane**
   (`release-ops` → "Crash and Error Reporting"). Keep the file as a build artifact too — the
   reporter is not an archive.
5. **Assemble the release build on every push.** R8, resource shrinking and the signing config only
   run in that configuration, so a lane that never builds it discovers what was stripped on release
   day.
6. **Play App Signing means two keys**, and only the upload one is in CI
   (`release-ops` → "Secrets in CI"). The App Link fingerprint must match the *signing* key Play uses, not the
   upload key — the source of the `assetlinks.json` mismatch that only reproduces from Play
   (`nav-deeplinks`).

## Permissions

1. **Ask in context, never at launch.** The prompt arrives when the user does the thing that needs
   it, with the reason already on screen; a launch-time wall of dialogs is denied by reflex and
   cannot be asked again.
2. **`shouldShowRequestPermissionRationale` before the second ask.** After two denials the system
   marks the permission permanently denied and the dialog stops appearing at all — from then on the
   only path is a link into app settings, so that fallback has to exist in the UI before it is
   needed.
3. **`POST_NOTIFICATIONS` is a runtime permission on 13+.** An app targeting 13+ shows no
   notification until it is granted; ask at the moment there is something worth notifying about, not
   during onboarding.
4. **Granular media on 13+.** `READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO` / `READ_MEDIA_AUDIO` replace
   `READ_EXTERNAL_STORAGE`, and 14+ adds partial "selected photos" access. The photo picker needs no
   permission at all — prefer it, and the whole branch disappears.
5. **`ACCESS_BACKGROUND_LOCATION` is a second, separate prompt** that can only be asked after
   foreground location is granted, and it puts the release in the policy-adjacent bucket
   (`## Distribution-channel review`).
6. **A permission has four states, not a boolean** — not asked, granted, denied, permanently denied
   — and each is a screen state (`compose-state`). Read the state on every resume: the user can
   change it in system settings while the app is backgrounded.

## Secure storage & transport

- **Secrets go in the store `persistence-architecture` → "Small Data" names.** What release adds is
  only the check: the release build must use the same store as debug, because a debug-only
  fallback that writes plaintext is a fallback that ships.
- **`network_security_config.xml` with cleartext off**, and user-added CAs trusted in
  `debug-overrides` only — so a developer's proxy works and a user's does not.

```xml
<!-- AndroidManifest.xml -->
<application android:networkSecurityConfig="@xml/network_security_config" ... />

<!-- res/xml/network_security_config.xml -->
<network-security-config>
    <base-config cleartextTrafficPermitted="false">
        <trust-anchors><certificates src="system" /></trust-anchors>
    </base-config>
    <debug-overrides>
        <trust-anchors><certificates src="system" /><certificates src="user" /></trust-anchors>
    </debug-overrides>
</network-security-config>
```

- **Pinning is OkHttp's `CertificatePinner`**, on the client `net-http-clients` configures. It takes
  SPKI hashes and nothing else, so the only choice is *whose* key: pin an intermediate's key with a
  backup, not only the leaf's, and always with **a written expiry plan** — a pin that outlives its
  certificate is an app that cannot reach its own backend and cannot be fixed without a release the
  users it locked out will never receive.
- **`BiometricPrompt` plus a Keystore key that requires user authentication** for a secret that must
  stay unreadable while the device is locked; the biometric result is worthless on its own if the key
  is not bound to it.
- **Backups leave the device.** `android:allowBackup` and the `dataExtractionRules` file decide
  whether a token ends up in a cloud backup; exclude the store that holds credentials explicitly.

## Accessibility

- **TalkBack labels on every interactive element.** `contentDescription` on a `View`; in Compose the
  `contentDescription` parameter of `Icon`/`Image`, or `Modifier.semantics { contentDescription = … }`
  on a custom control. A decorative image takes `null` on purpose — that is a decision, not an
  omission.
- **Merge composite controls into one node** with `Modifier.semantics(mergeDescendants = true)`, so
  a card of three texts is announced once, in order, instead of three separate stops.
- **Touch targets are 48 dp minimum.** Material 3 components apply
  `minimumInteractiveComponentSize` themselves; a bare `Modifier.clickable` on a 24 dp icon does not,
  and is the most common miss.
- **Font scaling to 200%.** Text sizes in `sp`, never `dp`, and the screen tested at a `fontScale`
  of `2.0` — a Compose preview takes it as a parameter, and the device has the setting. Non-linear
  font scaling on 14+ clips fixed-height rows that used to survive.
- **Verify rather than assume:** Accessibility Scanner on a device for the audit, plus Compose
  semantics assertions (`onNodeWithContentDescription`, `assertContentDescriptionEquals`) in the UI
  suite so a regression fails a lane rather than a user.
- **Honour reduced motion.** A zero `Settings.Global.ANIMATOR_DURATION_SCALE` means animations off;
  an app whose navigation depends on a transition that never runs is stuck.

## Common Mistakes

1. **Wiring `onMessageReceived` for a `notification` payload.** It works in every test, because the
   app under test is in the foreground, and silently stops working the moment a real user has the
   app backgrounded.
2. **Uploading the FCM token only from `onNewToken`.** The one delivery attempt fails, the callback
   never fires again, and that install stops receiving push forever.
3. **Requesting permissions at launch.** Two reflex denials later the system dialog is gone for good
   and the feature can only be recovered through a settings deep link nobody built.
4. **A preferences store for a token**, `EncryptedSharedPreferences` included —
   `persistence-architecture` → "Small Data".
5. **A certificate pin with no backup pin.** Certificate renewal day becomes an outage that only a
   store release can end.
6. **An icon button with no content description.** TalkBack announces "button", the pre-launch report
   flags it, and the fix is one line that nobody wrote because the screen looked fine.
7. **First release build on release day.** R8 stripped a class the JSON parser looks up by name, and
   the crash is in the release configuration only, at the worst possible moment.
8. **Promoting to production without reading the pre-launch report.** The OEM crash it found is now
   in the staged rollout, and the only way back is a new `versionCode`.
9. **Applying the fragmentation delta to everything, or to nothing.** Both make it useless: the first
   inflates every estimate until the delta is ignored, the second surfaces the OEM background bug as
   a schedule overrun.
