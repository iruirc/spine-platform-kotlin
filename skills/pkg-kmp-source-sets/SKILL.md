---
name: pkg-kmp-source-sets
description: "Use when laying out a Kotlin Multiplatform module — the default hierarchy template, intermediate source sets (jvmAndAndroid, native), expect/actual rules, per-source-set dependencies, target declaration, and publishing basics."
---

# KMP Source Sets

A multiplatform module is one Gradle module with several compilations, and the source-set tree decides
which file is visible to which target. Almost everything here is decided by getting one thing right:
how little of the code has to know what platform it is on. This skill lays out the tree, states the
`expect`/`actual` rules, and says which dependency may be declared where. Which modules exist at all
is `pkg-gradle-modules`.

> **Related skills:**
> - `pkg-gradle-modules` — whether this is even a module of its own, and what it may depend on
> - `arch-clean` — the `:domain` module that is all `commonMain`, and the `:data` module that owns the platform halves
> - `di-koin` — `expect val platformModule` and its `actual`s: the preferred alternative to an `expect class`
> - `nav-multiplatform` — the `Navigator` interface in `commonMain` and one implementation per host
> - `persistence-room-sqldelight` — a `commonMain` schema with a driver per target, the canonical shape
> - `net-http-clients` — why KMP forces Ktor, and where the per-target engine is declared
> - `architecture-choice` — the compass that reaches this skill as soon as the target is KMP

## When to Use

- A module is about to declare a second target, or an existing KMP module is gaining a file and
  nobody has said which source set it goes in
- Something must differ per platform and the shape of the seam has not been chosen
- User asks "where does this file go", "why can't I use this library in `commonMain`", "`expect class`
  or an interface", "do I need iOS targets if the iOS app is built elsewhere", "why does my `actual`
  not compile", "how do I share code between JVM and Android but not iOS"
- Review finds a JVM-only dependency in `commonMain`, an `expect class` mirroring twenty members, or
  the same file copied into `androidMain` and `jvmMain`
- The module is about to be published and the per-target artifacts have not been thought about

Not for the decision to go multiplatform at all, and not for the module graph around this module —
both are `pkg-gradle-modules` and `architecture-choice`. Not for what the shared code should *be*:
the layering is `arch-clean`.

## Default Hierarchy

Since Kotlin 1.9.20 the plugin applies a **default hierarchy template** as soon as targets are
declared — you get the intermediate source sets for free and write none of them:

```
commonMain
├── jvmMain
├── androidMain
├── jsMain / wasmJsMain          (under webMain since Kotlin 2.2.20)
└── nativeMain
    └── appleMain
        └── iosMain
            ├── iosArm64Main
            ├── iosSimulatorArm64Main
            └── iosX64Main
```

1. **Only the sets your targets need exist.** Declare `jvm()` and two iOS targets and you get
   `commonMain`, `jvmMain`, `nativeMain`, `appleMain`, `iosMain` and the two leaves — no `jsMain`, no
   `macosMain`. Every `*Main` has a `*Test` twin with the same shape. The `webMain` group over the two
   web targets is new in Kotlin 2.2.20; before that `jsMain` and `wasmJsMain` share nothing by
   default.
2. **`applyDefaultHierarchyTemplate()` is called for you.** Writing it by hand changes nothing; it is
   only worth writing when you are extending it (next section).
3. **A file goes in the highest source set that can hold it.** A rule shared by every target is
   `commonMain`; a native-only detail is `nativeMain`, not three copies in three leaves.
4. **Do not hand-declare a set the template already owns.** `val appleMain by creating` next to a
   template that already made `appleMain` is the confusing failure in this area; add files to it
   instead.
5. **Opt out only when you are replacing it.** `applyHierarchyTemplate { }` declares a custom tree, or
   `kotlin.mpp.applyDefaultHierarchyTemplate=false` in `gradle.properties` turns the default off for
   the whole build. Both mean every intermediate set becomes yours to declare and wire.
6. **There is no `jvmAndAndroid` in the default template.** JVM and Android are siblings under
   `commonMain`, which is deliberate: they are the same language and different platforms.

## Intermediate Source Sets

An intermediate source set is code shared by *some* targets. The template already gives you the
useful native ones; the group worth adding by hand is JVM plus Android:

```kotlin
@OptIn(ExperimentalKotlinGradlePluginApi::class)   // the hierarchy DSL is still experimental
kotlin {
    jvm()
    androidTarget()
    iosArm64(); iosSimulatorArm64()

    applyDefaultHierarchyTemplate {
        common {
            group("jvmAndAndroid") {
                withJvm()
                withAndroidTarget()
            }
        }
    }
}
```

1. **`jvmAndAndroid` is for what the JDK gives you and Kotlin/Native does not** — `java.time`, a JVM
   crypto provider, a JVM-only library with no multiplatform artifact. The group creates
   `jvmAndAndroidMain` and `jvmAndAndroidTest`; both targets see them, iOS does not.
2. **Adding a group keeps the rest of the template.** `applyDefaultHierarchyTemplate { }` with a block
   extends the default tree; it does not replace it.
3. **A group earns its keep at the second shared file.** One shared file is a duplicate you can live
   with; the third is a bug that was fixed in one copy.
4. **Never reach for a group to dodge an `expect`.** If the two platforms genuinely differ, the group
   only moves the duplication one level up.
5. **The native groups are already there.** `appleMain` for code shared by iOS and macOS targets,
   `nativeMain` for everything Kotlin/Native — including a target that runs on neither.

## expect and actual

The rule that decides the size of this problem: **`expect` the smallest thing that differs.**

```kotlin
// commonMain — the whole platform seam for this feature
expect fun currentTimeZoneId(): String

// androidMain
actual fun currentTimeZoneId(): String = java.util.TimeZone.getDefault().id

// iosMain
actual fun currentTimeZoneId(): String = NSTimeZone.localTimeZone.name
```

1. **`expect fun` and `expect val` before `expect class`.** An `expect class` forces every target to
   mirror the entire API — every constructor, every member, forever — and each new member is a
   compile error on every platform at once.
2. **An interface in `commonMain` plus a platform implementation injected by DI beats both.** The
   common code depends on the interface, each platform binds its own implementation, and the seam is
   testable with a fake — that is what `di-koin`'s `expect val platformModule` exists for, and it
   makes exactly one `expect` carry every platform binding in the module.
3. **`expect`/`actual` classes are still Beta.** The compiler warns, and silencing it takes the
   `-Xexpect-actual-classes` compiler argument. That warning is a design signal, not noise.
4. **An `actual` must live in a source set covering exactly the targets its `expect` compiles for.**
   An `expect` in `commonMain` needs every target covered; an `actual` in `iosMain` for an `expect`
   declared in `nativeMain` leaves every non-Apple native target unimplemented, and the error names
   the target, not the file.
5. **`actual typealias` is the shortest actual there is.** `actual typealias Uuid = java.util.UUID` on
   the JVM side beats a wrapper class nobody wanted.
6. **Zero `expect` in a module is the target, not a failure.** Most shared code needs a driver, a
   client engine or a context — and every one of those arrives as a constructor parameter
   (`persistence-room-sqldelight`, `net-http-clients`), which needs no `expect` at all.

## Dependencies per Source Set

```kotlin
kotlin {
    sourceSets {
        commonMain.dependencies {
            implementation(libs.kotlinx.coroutines.core)
            implementation(libs.kotlinx.datetime)
            implementation(libs.ktor.client.core)
        }
        androidMain.dependencies {
            implementation(libs.ktor.client.okhttp)
        }
        iosMain.dependencies {
            implementation(libs.ktor.client.darwin)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation(libs.kotlinx.coroutines.test)
        }
    }
}
```

1. **`commonMain` takes multiplatform artifacts only.** A multiplatform library publishes Gradle
   module metadata and one variant per target; the build picks the right one per compilation. A
   JVM-only artifact has no variant for `iosArm64`, and the build fails at resolution with "no
   matching variant" — at configuration time, before a line is compiled.
2. **Check the catalog before writing the line, not after.** The multiplatform ones a Kotlin project
   actually reaches for: `kotlinx-coroutines-core`, `kotlinx-serialization-json`, `kotlinx-datetime`,
   `ktor-client-*`, `sqldelight`, `koin-core`, `okio`. A `-jvm` suffix on the artifact id is the
   giveaway that a library is not one of them.
3. **`jvmMain` and `androidMain` may use anything on the JVM**, including a library with no
   multiplatform build at all. That is the reason `jvmAndAndroid` exists.
4. **A dependency declared in a source set reaches its descendants.** Declare it once in `commonMain`;
   repeating it in `iosMain` and `androidMain` is three places to bump a version.
5. **The engine is the per-target half of a `commonMain` API** — a Ktor engine, a SQLDelight driver, a
   platform context. The common set depends on the core artifact; each platform set adds its own
   implementation (`net-http-clients`, `persistence-room-sqldelight`).
6. **Test source sets follow the same tree.** `commonTest` for a test that must pass everywhere,
   `iosTest` only for what genuinely tests the iOS half.

## Targets

```kotlin
kotlin {
    jvm()
    androidTarget()                 // requires an Android Gradle plugin on this module
    listOf(iosArm64(), iosSimulatorArm64(), iosX64()).forEach {
        it.binaries.framework { baseName = "Shared" }   // what the iOS build links against
    }
    macosArm64()
    js(IR) { browser() }            // IR is the only backend now; the argument is optional
    wasmJs { browser() }            // needs @OptIn(ExperimentalWasmDsl::class)
}
```

1. **Declare a target only if something builds it.** Each one costs compile time on every build and a
   set of source sets to keep honest; `iosX64()` in a project whose simulators are all Apple silicon
   is pure cost.
2. **`androidTarget()` needs an Android plugin on the module** — `com.android.library`, or the
   multiplatform-shaped `com.android.kotlin.multiplatform.library`. That is a plugin on the module's
   classpath, which is exactly why `arch-clean` keeps `androidTarget()` off `:domain` and lets Android
   consumers take the `jvm()` variant instead.
3. **Declare the iOS targets even when the iOS app is built by its own build tool.** The framework
   that app consumes is produced *by these targets*; without them there is nothing to hand over.
4. **`binaries.framework { }` is the hand-over point.** It names the framework the other build tool
   links against; the packaging of it belongs to that tool and not to this file.
5. **Apple targets build only on an Apple host.** A Linux CI lane can build the JVM and Android halves
   and must be told to skip the rest (see Publishing); the Apple lane is a second lane
   (`release-ops`).
6. **The target list is a commitment.** Adding one later can turn a `commonMain` dependency into a
   resolution failure, because the library you picked may have no variant for it.

## Publishing

1. **`maven-publish` beside `kotlin("multiplatform")` is the whole setup.** The plugin creates one
   publication per target plus a root metadata publication; a consumer depends on the root
   coordinate and Gradle resolves the variant for its own platform.
2. **Set `group` and `version` on the project**, and use `publishing { publications { } }` only to
   adjust coordinates or POM metadata on the publications the plugin already made — creating your own
   publication for a KMP module fights the plugin.
3. **Publish from a host that can build every target.** A partial publish produces a root module
   whose metadata promises variants that were never uploaded, and the consumer's failure is a
   resolution error far from here.
4. **`kotlin.native.ignoreDisabledTargets=true`** lets a build that declares Apple targets configure
   and run on a host that cannot build them — the lane that only checks the JVM half.
5. **`kotlin.mpp.enableCInteropCommonization=true`** when a cinterop library is used from an
   intermediate native source set such as `appleMain`; without it the interop bindings are visible
   only in the leaf target sets.
6. **Consumers need Gradle module metadata.** It is on by default; a build that disables it publishes
   a POM-only artifact and every non-JVM consumer of this library stops resolving.

## Common Mistakes

1. **A JVM-only artifact in `commonMain`** — the most common first failure, and the message ("no
   matching variant for `iosArm64`") reads like a repository problem. Check the artifact for a
   multiplatform publication; if there is none, the code that uses it belongs in `jvmAndAndroid` or
   behind an interface.
2. **`expect class` for everything.** Every member has to be mirrored on every platform, an added
   parameter breaks all of them at once, and the class cannot be faked in a common test. An interface
   plus a platform binding does the same job with one seam (`di-koin`).
3. **An `actual` in the wrong source set.** Put in `iosMain` for an `expect` that `commonMain`
   declared, it leaves JVM and Android unimplemented; put in a leaf like `iosArm64Main`, it leaves the
   simulator target out. The `actual` goes in the set that covers exactly the `expect`'s targets.
4. **An `actual` in `iosMain` for an `expect` declared in `nativeMain`.** It compiles as long as iOS is
   the only native target, and breaks the day `macosArm64()` is added — long after the person who
   wrote it moved on.
5. **`androidMain` code that should be `jvmAndAndroid`.** The JVM copy appears a week later, the two
   drift, and the bug is fixed in one of them. If the file only needs the JDK, it belongs to the group.
6. **Skipping the iOS targets because "the iOS app is native".** Nothing then produces the framework
   that app was going to consume, and the discovery happens at integration time.
7. **Hand-declaring a source set the template already made.** `val appleMain by creating` beside the
   default template produces a set that looks right and compiles into nothing.
8. **The same dependency repeated in every leaf source set.** It belongs in the nearest common
   ancestor; four copies of a version is four chances to upgrade three of them.
