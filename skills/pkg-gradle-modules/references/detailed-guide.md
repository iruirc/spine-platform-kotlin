# pkg-gradle-modules — detailed guide

## Contents

- The Build It Wires
- Settings and the Included Build
- The build-logic Build File
- Convention Plugins
- Precompiled Script Plugins
- The Version Catalog
- Module Build Files
- Enforcing the Graph
- gradle.properties
- Composite Build
- Test Fixtures

## The Build It Wires

The build it wires is an orders app with six modules, one per archetype: `:app` (entry point and
composition root), `:feature:orders`, `:core:designsystem`, `:core:model`, `:data:orders`, and
`:api:orders` — the contract a second feature would reach orders through.

## Settings and the Included Build

```kotlin
// settings.gradle.kts
pluginManagement {
    // The convention plugins live in a build of their own; this makes their ids resolvable.
    includeBuild("build-logic")
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    // A module with its own `repositories { }` resolves differently, and fails differently on CI.
    repositoriesMode = RepositoriesMode.FAIL_ON_PROJECT_REPOS
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "orders"

include(":app", ":feature:orders", ":core:designsystem", ":core:model", ":data:orders", ":api:orders")
```

```kotlin
// build-logic/settings.gradle.kts — an ordinary Gradle build with one project in it
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
    versionCatalogs {
        create("libs") {
            // Relative to build-logic/: one file, two builds, no second place to write a version.
            from(files("../gradle/libs.versions.toml"))
        }
    }
}

rootProject.name = "build-logic"
```

1. The main build declares no catalog: `gradle/libs.versions.toml` is picked up by name, and a
   `create("libs") { from(files(...)) }` beside it fails the build: "you can only call the 'from'
   method a single time".
2. build-logic is a separate build with its own root directory, so the default location does not
   reach the file; its settings name it. What that declaration buys is the `libs` accessor in
   build-logic's *own* build file, below — not in the convention plugins it compiles.

## The build-logic Build File

```kotlin
// build-logic/build.gradle.kts
plugins {
    // Applies java-gradle-plugin too, which is where the gradlePlugin { } block below comes from.
    `kotlin-dsl`
}

dependencies {
    // compileOnly: the conventions compile against these; the root build file loads them at runtime.
    compileOnly(libs.android.gradlePlugin)
    compileOnly(libs.kotlin.gradlePlugin)
    compileOnly(libs.compose.gradlePlugin)
}

gradlePlugin {
    // Binary plugins only: `orders.jvm.library` is a precompiled script, registered by its file name.
    plugins {
        register("androidApplication") {
            id = "orders.android.application"
            implementationClass = "AndroidApplicationConventionPlugin"
        }
        register("androidLibrary") {
            id = "orders.android.library"
            implementationClass = "AndroidLibraryConventionPlugin"
        }
        register("androidFeature") {
            id = "orders.android.feature"
            implementationClass = "AndroidFeatureConventionPlugin"
        }
    }
}
```

```kotlin
// build.gradle.kts — the root, which loads every plugin once, at the catalog's version
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.android.kotlin.multiplatform.library) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.multiplatform) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.ksp) apply false
}
```

1. The plugin *artifacts* are ordinary `[libraries]` entries — `android-gradlePlugin` points at
   `com.android.tools.build:gradle` — so `libs.android.gradlePlugin` needs no helper. The alternative
   other repositories use is a hand-written `fun Provider<PluginDependency>.toDep()` that turns a
   `[plugins]` entry into a dependency notation and avoids writing the coordinate twice — a real
   saving against one more piece of build vocabulary that exists here and nowhere else. Prefer the
   artifact form until the duplicate coordinate actually causes a mismatch.
2. `compileOnly` and the root's `apply false` are one decision. With `implementation`, every module
   that applies a convention gets build-logic's copy of the Kotlin plugin while a module that names
   a plugin by `alias(...)` loads its own, and Gradle warns that "the Kotlin Gradle plugin was loaded
   multiple times". The root loads each plugin once, every module sees that copy, and a module's own
   `alias(libs.plugins.ksp)` resolves to it.
3. No `java { }` or JVM target here: build-logic runs inside the Gradle daemon that compiles it.

## Convention Plugins

Three classes and the helper they share, under `build-logic/src/main/kotlin/`.
`orders.jvm.library` is not among them — it is the precompiled script in the next section.
The helper carries the version-catalog lookup and the test wiring, the two parts of the setup that
are not obvious.

```kotlin
// build-logic/src/main/kotlin/AndroidConventions.kt
import com.android.build.api.dsl.CommonExtension
import org.gradle.api.JavaVersion
import org.gradle.api.Project
import org.gradle.api.artifacts.VersionCatalogsExtension
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.dependencies
import org.gradle.kotlin.dsl.getByType
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension

internal fun Project.configureAndroid(android: CommonExtension) {
    android.compileSdk = 37
    android.defaultConfig.minSdk = 24
    android.compileOptions.sourceCompatibility = JavaVersion.VERSION_17
    // KGP checks the Kotlin jvmTarget against this one, and a mismatch fails the build.
    android.compileOptions.targetCompatibility = JavaVersion.VERSION_17
    android.testOptions.unitTests.all { it.useJUnitPlatform() }
    extensions.configure<KotlinAndroidProjectExtension> {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
            allWarningsAsErrors.set(true)
        }
    }
    val libs = extensions.getByType<VersionCatalogsExtension>().named("libs")
    dependencies {
        add("testImplementation", platform(libs.findLibrary("junit-bom").get()))
        add("testImplementation", libs.findLibrary("junit-jupiter").get())
        add("testRuntimeOnly", libs.findLibrary("junit-platform-launcher").get())
        add("testRuntimeOnly", libs.findLibrary("junit-vintage-engine").get())
    }
}
```

1. **`CommonExtension` is what `ApplicationExtension` and `LibraryExtension` share**, which is why the
   SDK and JVM settings live in one place. On AGP 9 it takes no type arguments and has no
   `defaultConfig { }` or `compileOptions { }` blocks of its own — the properties are what it has.
2. **AGP 9 compiles Kotlin itself.** No convention applies `org.jetbrains.kotlin.android`: beside
   AGP 9 it fails the build ("no longer required for Kotlin support since AGP 9.0"). The `kotlin { }`
   extension configured above is the one AGP registers.
3. **No `libs` accessor exists in build-logic's sources.** `VersionCatalogsExtension` on the target
   project is the way in, and it reads the catalog of the build that *applies* the plugin — here the
   same file, by the settings above.
4. **JUnit 5 on Android takes the same wiring as on the JVM** — Jupiter, the launcher, and
   `useJUnitPlatform()` on every unit-test task. Without `useJUnitPlatform()` the task finds no test
   and Gradle fails it ("did not discover any tests to execute"); without the launcher it cannot
   start ("Failed to load JUnit Platform"). The vintage engine keeps the JUnit4 tests a Compose rule
   or Robolectric forces running beside them: without it the platform skips them, and the task
   still passes. How the tests themselves are written is `test-frameworks` → "JUnit5".

```kotlin
// build-logic/src/main/kotlin/AndroidLibraryConventionPlugin.kt
import com.android.build.api.dsl.LibraryExtension
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.artifacts.VersionCatalogsExtension
import org.gradle.kotlin.dsl.dependencies
import org.gradle.kotlin.dsl.getByType

class AndroidLibraryConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("com.android.library")
        val libs = extensions.getByType<VersionCatalogsExtension>().named("libs")

        configureAndroid(extensions.getByType<LibraryExtension>())
        dependencies {
            add("testImplementation", libs.findLibrary("kotlinx-coroutines-test").get())
        }
        registerGraphRuleCheck()   // see "Enforcing the Graph"
    }
}
```

```kotlin
// build-logic/src/main/kotlin/AndroidApplicationConventionPlugin.kt
import com.android.build.api.dsl.ApplicationExtension
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.getByType

// :app has its own convention: an application project has no LibraryExtension to configure.
class AndroidApplicationConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("com.android.application")
        pluginManager.apply("org.jetbrains.kotlin.plugin.compose")

        val application = extensions.getByType<ApplicationExtension>()
        configureAndroid(application)
        application.apply {
            defaultConfig { targetSdk = 36 }
            buildFeatures { compose = true }
        }
        registerGraphRuleCheck()
    }
}
```

```kotlin
// build-logic/src/main/kotlin/AndroidFeatureConventionPlugin.kt
import com.android.build.api.dsl.LibraryExtension
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.artifacts.VersionCatalogsExtension
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.dependencies
import org.gradle.kotlin.dsl.getByType

// Composing convention plugins by id is what keeps the Android defaults in exactly one file.
class AndroidFeatureConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("orders.android.library")
        pluginManager.apply("org.jetbrains.kotlin.plugin.compose")
        val libs = extensions.getByType<VersionCatalogsExtension>().named("libs")
        extensions.configure<LibraryExtension> { buildFeatures { compose = true } }

        dependencies {
            // A baseline, not a feature edge: a project(...) line here would hide one from the graph rules.
            add("implementation", platform(libs.findLibrary("androidx-compose-bom").get()))
            add("implementation", libs.findLibrary("androidx-lifecycle-viewmodel-compose").get())
            add("testImplementation", libs.findLibrary("turbine").get())
        }
    }
}
```

`targetSdk = 36` is the level Google Play requires of new apps and updates (`release-ops-android`);
`compileSdk` may run ahead of it, and here does.

## Precompiled Script Plugins

The same convention as a build script whose *file name is the plugin id* — nothing registered, no
`implementationClass`; `kotlin-dsl` compiles the file into a plugin.

```kotlin
// build-logic/src/main/kotlin/orders.jvm.library.gradle.kts
import org.gradle.api.artifacts.VersionCatalogsExtension
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("org.jetbrains.kotlin.jvm")
}

// Type-safe accessors exist here for the plugins applied above, and only for those.
java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
        allWarningsAsErrors.set(true)
    }
}

// No `libs` accessor here either: the same lookup as the binary plugins.
val libs = extensions.getByType<VersionCatalogsExtension>().named("libs")

dependencies {
    "testImplementation"(platform(libs.findLibrary("junit-bom").get()))
    "testImplementation"(libs.findLibrary("junit-jupiter").get())
    "testRuntimeOnly"(libs.findLibrary("junit-platform-launcher").get())
}

tasks.withType<Test>().configureEach { useJUnitPlatform() }
registerGraphRuleCheck()   // a top-level Project extension in build-logic resolves here too
```

This is the only form `orders.jvm.library` takes: it has no entry in `gradlePlugin { }`,
because a script plugin is registered by its file name. Writing both a class and a script for one id
is the one way to get two plugins that disagree.

1. **`libs.junit.jupiter` does not compile here** — "Unresolved reference 'libs'" — even though
   build-logic's settings declare the catalog: that declaration serves build-logic's own build file,
   and a precompiled script is compiled as a plugin for some other build.
2. **The Java and Kotlin targets are set as a pair**, the same pair the Android helper sets. Setting
   only the Java one fails the build: "Inconsistent JVM-target compatibility detected for tasks
   'compileJava' (17) and 'compileKotlin' (25)". A
   `java { toolchain { } }` sets both at once, and in exchange needs that JDK installed or a
   toolchain resolver in the settings.
3. **The launcher is `testRuntimeOnly`, and Gradle 9 no longer supplies it.** Without it every test
   task fails before the first test: "Failed to load JUnit Platform".

Which form to take:

1. **Precompiled scripts first.** They read exactly like a module's own build file, so anyone who can
   edit a `build.gradle.kts` can edit one — which for four conventions is the whole job.
2. **Binary plugins once the conventions share code** — a helper both Android plugins call, a block
   applied only when another plugin is present (`pluginManager.withPlugin(...)`), or a plugin worth
   unit-testing with `ProjectBuilder`. Both forms may coexist; one id written half in each may not.

## The Version Catalog

<!-- compile: catalog -->
```toml
# gradle/libs.versions.toml — every version in the build is in this file
[versions]
agp = "9.4.1"
kotlin = "2.4.20"
ksp = "2.3.12"
compose-bom = "2026.09.00"
coroutines = "1.11.0"
serialization = "1.11.0"
datetime = "0.8.0"
lifecycle = "2.11.0"
ktor = "3.6.0"
room = "2.8.5"
junit-jupiter = "5.14.4"
turbine = "1.2.1"

[libraries]
# Plugin artifacts, for build-logic's compile classpath.
android-gradlePlugin = { module = "com.android.tools.build:gradle", version.ref = "agp" }
kotlin-gradlePlugin = { module = "org.jetbrains.kotlin:kotlin-gradle-plugin", version.ref = "kotlin" }
compose-gradlePlugin = { module = "org.jetbrains.kotlin:compose-compiler-gradle-plugin", version.ref = "kotlin" }

androidx-compose-bom = { module = "androidx.compose:compose-bom", version.ref = "compose-bom" }
androidx-compose-material3 = { module = "androidx.compose.material3:material3" }
androidx-lifecycle-viewmodel-compose = { module = "androidx.lifecycle:lifecycle-viewmodel-compose", version.ref = "lifecycle" }
kotlinx-coroutines-core = { module = "org.jetbrains.kotlinx:kotlinx-coroutines-core", version.ref = "coroutines" }
kotlinx-coroutines-test = { module = "org.jetbrains.kotlinx:kotlinx-coroutines-test", version.ref = "coroutines" }
kotlinx-serialization-json = { module = "org.jetbrains.kotlinx:kotlinx-serialization-json", version.ref = "serialization" }
kotlinx-datetime = { module = "org.jetbrains.kotlinx:kotlinx-datetime", version.ref = "datetime" }
ktor-client-core = { module = "io.ktor:ktor-client-core", version.ref = "ktor" }
ktor-client-okhttp = { module = "io.ktor:ktor-client-okhttp", version.ref = "ktor" }
ktor-client-content-negotiation = { module = "io.ktor:ktor-client-content-negotiation", version.ref = "ktor" }
ktor-serialization-kotlinx-json = { module = "io.ktor:ktor-serialization-kotlinx-json", version.ref = "ktor" }
androidx-room-runtime = { module = "androidx.room:room-runtime", version.ref = "room" }
androidx-room-compiler = { module = "androidx.room:room-compiler", version.ref = "room" }
junit-bom = { module = "org.junit:junit-bom", version.ref = "junit-jupiter" }
junit-jupiter = { module = "org.junit.jupiter:junit-jupiter" }
junit-platform-launcher = { module = "org.junit.platform:junit-platform-launcher" }
junit-vintage-engine = { module = "org.junit.vintage:junit-vintage-engine" }
turbine = { module = "app.cash.turbine:turbine", version.ref = "turbine" }

[bundles]
# Artifacts that are always added together and always upgraded together: the client, an engine,
# and the serializer it negotiates content with. One of them alone does not make a working client.
ktor-client = ["ktor-client-core", "ktor-client-okhttp", "ktor-client-content-negotiation", "ktor-serialization-kotlinx-json"]

[plugins]
android-application = { id = "com.android.application", version.ref = "agp" }
android-library = { id = "com.android.library", version.ref = "agp" }
android-kotlin-multiplatform-library = { id = "com.android.kotlin.multiplatform.library", version.ref = "agp" }
kotlin-jvm = { id = "org.jetbrains.kotlin.jvm", version.ref = "kotlin" }
kotlin-multiplatform = { id = "org.jetbrains.kotlin.multiplatform", version.ref = "kotlin" }
kotlin-compose = { id = "org.jetbrains.kotlin.plugin.compose", version.ref = "kotlin" }
kotlin-serialization = { id = "org.jetbrains.kotlin.plugin.serialization", version.ref = "kotlin" }
ksp = { id = "com.google.devtools.ksp", version.ref = "ksp" }
```

1. `androidx-compose-material3` and `junit-jupiter` carry no version on purpose: a BOM supplies it,
   and a version here would win over the BOM and silently defeat it. Accessors drop the dashes —
   `libs.kotlinx.coroutines.core`, `libs.bundles.ktor.client`, `alias(libs.plugins.kotlin.jvm)`.
2. A `[plugins]` entry is what `alias(...)` reads and cannot be used as a dependency; a `[libraries]`
   entry is the reverse. There is no `kotlin-android` entry: AGP 9 compiles Kotlin itself. KSP is
   versioned on its own line since 2.3 (`2.3.12`) and no longer names a Kotlin version, so it is
   upgraded like any other plugin.

## Module Build Files

Five files, one per archetype. What each one is *missing* is the design.

```kotlin
// :app/build.gradle.kts — the only module that names every other module
plugins { id("orders.android.application") }

android {
    namespace = "com.example.orders"
    defaultConfig { applicationId = "com.example.orders"; versionCode = 1; versionName = "1.0" }
}

dependencies {
    implementation(project(":feature:orders"))
    implementation(project(":data:orders"))       // bound to the domain interfaces here, nowhere else
    implementation(project(":core:designsystem"))
    implementation(project(":core:model"))
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.material3)
}
```

```kotlin
// :feature:orders/build.gradle.kts — the absent lines are project(":feature:cart") and
// project(":data:orders"): the repository interface lives in :core:model and :app binds it.
plugins { id("orders.android.feature") }

android { namespace = "com.example.feature.orders" }

dependencies {
    implementation(project(":core:designsystem"))
    implementation(project(":core:model"))
    implementation(project(":api:orders"))
}
```

```kotlin
// :core:model/build.gradle.kts — no project(...) line exists, and that is the archetype
plugins { id("orders.jvm.library") }

dependencies {
    api(libs.kotlinx.datetime)   // LocalDate appears in this module's own signatures
}
```

```kotlin
// :data:orders/build.gradle.kts — every framework in the build lands here
plugins {
    id("orders.android.library")
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
}

android { namespace = "com.example.data.orders" }

dependencies {
    api(project(":api:orders"))         // this module hands back the contract's types
    implementation(project(":core:model"))
    implementation(libs.bundles.ktor.client)
    implementation(libs.androidx.room.runtime)
    ksp(libs.androidx.room.compiler)
}
```

```kotlin
// :api:orders/build.gradle.kts — interfaces and DTOs, and a build file to match
plugins {
    id("orders.jvm.library")
    alias(libs.plugins.kotlin.serialization)
}

dependencies {
    // @Serializable is on the DTOs here, so the format's runtime is part of the contract.
    implementation(libs.kotlinx.serialization.json)
}
```

1. `:app` gets its own convention rather than the feature one: `com.android.application` and
   `com.android.library` cannot both be applied to a project, and the feature convention configures a
   `LibraryExtension`, which an application project does not have. The two Android conventions share
   `configureAndroid`; what differs is the extension type and the two application-only settings.
2. `:data:orders` holds the build's one `api(project(...))`, for the stated reason: its repository
   returns `:api:orders` types. Everything else is `implementation` — the check is deleting the
   keyword and seeing what breaks.
3. `:api:orders` names no other module of this build. External artifacts it does have — a
   serialization runtime is part of the contract — but the first `project(...)` line it wants is the
   question of whether an implementation has moved in.
4. `:feature:orders` has no `:data:orders` line even though the archetype table allows one. On a
   Clean layout it never does: the interface is in `:core:model` and `:app` binds the implementation.
5. `alias(libs.plugins.ksp)` names a version and still loads the root's copy, because the root
   declared the same one with `apply false`.
6. `kotlinx-datetime` is there for `LocalDate` and time zones; `Instant` is `kotlin.time.Instant` in
   the standard library, and `kotlinx.datetime.Instant` is deprecated — under `allWarningsAsErrors`
   one use of it fails the module.

## Enforcing the Graph

One task per module, registered by the convention plugin, checking only that module's own
dependencies: nothing reads another project's state, and the rule survives the configuration cache.

```kotlin
// build-logic/src/main/kotlin/GraphRules.kt
import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.Project
import org.gradle.api.artifacts.ProjectDependency
import org.gradle.api.provider.Property
import org.gradle.api.provider.SetProperty
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.TaskAction
import org.gradle.kotlin.dsl.register

private val CHECKED = setOf("api", "implementation", "compileOnly")

private val ALLOWED = mapOf(   // keyed by first path segment: :feature:orders -> "feature"
    "app" to setOf("feature", "core", "data", "api"),
    "feature" to setOf("core", "data", "api"),   // "data" allowed, unused on a Clean layout
    "data" to setOf("core", "api"),
    "core" to emptySet(),
    "api" to emptySet(),
)

private fun archetypeOf(path: String) = path.removePrefix(":").substringBefore(':')

abstract class CheckModuleDependencies : DefaultTask() {
    @get:Input abstract val modulePath: Property<String>
    @get:Input abstract val dependencyPaths: SetProperty<String>

    @TaskAction
    fun check() {
        val from = archetypeOf(modulePath.get())
        val allowed = ALLOWED[from] ?: return
        val bad = dependencyPaths.get().filter { archetypeOf(it) !in allowed }
        if (bad.isNotEmpty()) {
            throw GradleException("${modulePath.get()} ($from) may not depend on ${bad.sorted()}")
        }
    }
}

fun Project.registerGraphRuleCheck() {
    // `project` inside a provider used as a task input is resolved during configuration; only a
    // `project` read from inside @TaskAction breaks the configuration cache. ProjectDependency.path
    // needs Gradle 8.11+; before that it is dependencyProject.path.
    val edges = provider {
        configurations.filter { it.name in CHECKED }
            .flatMap { c -> c.dependencies.filterIsInstance<ProjectDependency>().map { it.path } }
            .toSet()
    }
    val check = tasks.register<CheckModuleDependencies>("checkModuleDependencies") {
        modulePath.set(path)
        dependencyPaths.set(edges)
    }
    tasks.named("check") { dependsOn(check) }
}
```

1. Feature-to-feature falls out of the same map: `"feature"` is not in its own allowed set, so
   `:feature:orders` naming `:feature:cart` fails with both paths in the message. It runs on `check`,
   so a CI lane already invokes it (`release-ops`) and nobody memorizes a task name.
2. Konsist and ArchUnit answer the neighbouring question — which *package* may import which — and are
   worth having inside a module that stayed single. Neither sees Gradle edges.

## gradle.properties

```properties
org.gradle.jvmargs=-Xmx4g -XX:+UseParallelGC -XX:MaxMetaspaceSize=1g
org.gradle.parallel=true
org.gradle.caching=true
org.gradle.configuration-cache=true
kotlin.incremental=true
kotlin.daemon.jvmargs=-Xmx2g
android.useAndroidX=true
```

The configuration cache is the one that needs code changed to earn it. The whole rule, in two tasks:

```kotlin
// Breaks it: the action reaches for `project` while the task runs.
tasks.register("brokenVersion") { doLast { println(project.version) } }

// Earns it: the value is read during configuration and carried as an input.
abstract class PrintVersion : DefaultTask() {
    @get:Input abstract val version: Property<String>
    @TaskAction fun run() = println(version.get())
}
tasks.register<PrintVersion>("printVersion") { version.set(project.version.toString()) }
```

1. The failure report is an HTML file whose link Gradle prints, naming every offending task and the
   line that touched `project`. Fix them one at a time — the cache is all-or-nothing per build.
2. `kotlin.daemon.jvmargs` sizes the Kotlin compile daemon, a different process from the Gradle daemon
   `org.gradle.jvmargs` sizes. Measure with `--scan` before and after any of this, and reach for
   `gradle-profiler` when a change is worth defending.

## Composite Build

```kotlin
// settings.gradle.kts — the sibling repository replaces its own published coordinate
includeBuild("../shared-lib") {
    dependencySubstitution {
        substitute(module("com.example:shared")).using(project(":"))
    }
}
```

1. The substitution block is needed only when the coordinates do not line up. If `../shared-lib`
   already declares `group = "com.example"` and its root project is named `shared`, `includeBuild`
   alone substitutes it.
2. Module files do not change: they keep `implementation(libs.shared)` and resolve to the checkout.
   Verify with
   `./gradlew :data:orders:dependencyInsight --configuration debugRuntimeClasspath --dependency com.example:shared`
   — an Android module has one classpath per variant, so the task needs to be told which one.
3. CI builds against the published artifact, always: a composite that is the only way the code
   compiles is a merge nobody else can reproduce. Each included build is a full Gradle build with its
   own configuration phase, so past two or three, publishing to a local repository is faster.

## Test Fixtures

```kotlin
// :core:model/build.gradle.kts
plugins {
    id("orders.jvm.library")
    `java-test-fixtures`
}

dependencies {
    api(libs.kotlinx.datetime)
}
```

<!-- compile: jvm -->
```kotlin
// :core:model src/testFixtures/kotlin/com/example/model/OrderFixtures.kt
package com.example.model

import kotlin.time.Instant

// Compiled into its own variant: on a consumer's test classpath, never in the production artifact.
fun order(
    id: OrderId = OrderId("o-1"),
    placedAt: Instant = Instant.parse("2026-01-01T00:00:00Z"),
    lines: List<OrderLine> = listOf(orderLine()),
) = Order(id, placedAt, lines)
```

1. The consumer side is one line: `testImplementation(testFixtures(project(":core:model")))`. An
   Android library enables the same source set with `android { testFixtures { enable = true } }`
   instead of the `java-test-fixtures` plugin; that consumer line is identical.
2. The fixtures source set already sees the module's own `api` dependencies; anything it needs on top
   goes in `testFixturesImplementation`, which reaches no production classpath.
3. Fixtures belong to the module that owns the types they fake; a `:core:testing` module is right only
   for helpers no single module owns. The alternative is three copies in three `src/test/` trees, and
   the one you fixed is never the one the failing test used.
