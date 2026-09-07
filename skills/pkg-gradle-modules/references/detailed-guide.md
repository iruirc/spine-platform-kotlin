# pkg-gradle-modules — detailed guide

One build wired end to end: the settings file, the `build-logic` included build and its convention
plugins, the catalog every version comes from, one build file per archetype, the task that fails when
a graph rule is broken, the performance properties, and the two shapes that appear only in a larger
project — a composite build and published test fixtures. Load the section you need, not the file.

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
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
    // Redundant for the default name and location; written out because build-logic's own settings
    // file must repeat it, and the two being visibly one catalog is the point.
    versionCatalogs {
        create("libs") {
            from(files("gradle/libs.versions.toml"))
        }
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

## The build-logic Build File

```kotlin
// build-logic/build.gradle.kts
plugins {
    // Applies java-gradle-plugin too, which is where the gradlePlugin { } block below comes from.
    `kotlin-dsl`
}

java { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }

dependencies {
    // Plugin *artifacts*, not plugin ids: a convention plugin applies these by id at runtime and
    // needs their classes on its own compile classpath to configure LibraryExtension and friends.
    implementation(libs.android.gradlePlugin)
    implementation(libs.kotlin.gradlePlugin)
    implementation(libs.compose.gradlePlugin)
}

gradlePlugin {
    // Binary plugins only. `kotlin-platform.jvm.library` is a precompiled script two sections down,
    // and a script plugin registers itself by its file name.
    plugins {
        register("androidApplication") {
            id = "kotlin-platform.android.application"
            implementationClass = "AndroidApplicationConventionPlugin"
        }
        register("androidLibrary") {
            id = "kotlin-platform.android.library"
            implementationClass = "AndroidLibraryConventionPlugin"
        }
        register("androidFeature") {
            id = "kotlin-platform.android.feature"
            implementationClass = "AndroidFeatureConventionPlugin"
        }
    }
}
```

Those lines use the plain `[libraries]` form: `android-gradlePlugin` is an ordinary catalog entry
pointing at `com.android.tools.build:gradle`, so `libs.android.gradlePlugin` needs no helper. The
alternative other repositories use is a hand-written `fun Provider<PluginDependency>.toDep()` that
turns a `[plugins]` entry into a dependency notation and avoids writing the coordinate twice — a real
saving against one more piece of build vocabulary that exists here and nowhere else. Prefer the
artifact form until the duplicate coordinate actually causes a mismatch.

## Convention Plugins

Three classes and the helper they share, under `build-logic/src/main/kotlin/`.
`kotlin-platform.jvm.library` is not among them — it is the precompiled script in the next section.
The library plugin carries the version-catalog lookup, the only part of the setup that is not
obvious.

```kotlin
// build-logic/src/main/kotlin/AndroidConventions.kt
// imports: ApplicationExtension, CommonExtension, LibraryExtension, VersionCatalogsExtension,
// JvmTarget, KotlinAndroidProjectExtension, and the org.gradle.kotlin.dsl helpers.
// The half both Android conventions share. CommonExtension is what ApplicationExtension and
// LibraryExtension have in common, which is why the SDK and JVM settings can live in one place.
internal fun Project.configureAndroid(commonExtension: CommonExtension<*, *, *, *, *, *>) {
    commonExtension.apply {
        compileSdk = 35
        defaultConfig { minSdk = 24 }
        compileOptions {
            sourceCompatibility = JavaVersion.VERSION_17
            // Set both: KGP validates the Kotlin jvmTarget against the Java target, and a mismatch
            // fails the build rather than warning.
            targetCompatibility = JavaVersion.VERSION_17
        }
    }
    extensions.configure<KotlinAndroidProjectExtension> {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
            allWarningsAsErrors.set(true)
        }
    }
}
```

```kotlin
// build-logic/src/main/kotlin/AndroidLibraryConventionPlugin.kt
class AndroidLibraryConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("com.android.library")
        pluginManager.apply("org.jetbrains.kotlin.android")
        // build-logic gets no `libs` accessor — it is generated for the main build's scripts. This
        // lookup is the way in, and why the catalog is declared in build-logic's settings file.
        val libs = extensions.getByType<VersionCatalogsExtension>().named("libs")

        configureAndroid(extensions.getByType<LibraryExtension>())
        dependencies {
            add("testImplementation", libs.findLibrary("junit").get())
            add("testImplementation", libs.findLibrary("kotlinx-coroutines-test").get())
        }
        registerGraphRuleCheck()   // see "Enforcing the Graph"
    }
}
```

```kotlin
// build-logic/src/main/kotlin/AndroidApplicationConventionPlugin.kt
// :app needs its own convention: com.android.application and com.android.library cannot both be
// applied to one project, and the feature convention configures a LibraryExtension.
class AndroidApplicationConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("com.android.application")
        pluginManager.apply("org.jetbrains.kotlin.android")
        pluginManager.apply("org.jetbrains.kotlin.plugin.compose")

        val application = extensions.getByType<ApplicationExtension>()
        configureAndroid(application)
        application.apply {
            defaultConfig { targetSdk = 35 }
            buildFeatures { compose = true }
        }
        registerGraphRuleCheck()
    }
}
```

```kotlin
// build-logic/src/main/kotlin/AndroidFeatureConventionPlugin.kt
// Composing convention plugins by id is what keeps the Android defaults in exactly one file.
class AndroidFeatureConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.apply("kotlin-platform.android.library")
        pluginManager.apply("org.jetbrains.kotlin.plugin.compose")
        val libs = extensions.getByType<VersionCatalogsExtension>().named("libs")
        extensions.configure<LibraryExtension> { buildFeatures { compose = true } }

        dependencies {
            // The archetype's UI baseline is a default; a `project(":core:analytics")` line here
            // would be a dependency, and would hide an edge the graph rules must see.
            add("implementation", platform(libs.findLibrary("androidx-compose-bom").get()))
            add("implementation", libs.findLibrary("androidx-lifecycle-viewmodel-compose").get())
            add("testImplementation", libs.findLibrary("turbine").get())
        }
    }
}
```

## Precompiled Script Plugins

The same convention as a build script whose *file name is the plugin id* — nothing registered, no
`implementationClass`; `kotlin-dsl` compiles the file into a plugin.

```kotlin
// build-logic/src/main/kotlin/kotlin-platform.jvm.library.gradle.kts
import org.gradle.api.artifacts.VersionCatalogsExtension

plugins {
    id("org.jetbrains.kotlin.jvm")
}

// Type-safe accessors exist here for the plugins applied above, and only for those.
java {
    toolchain { languageVersion.set(JavaLanguageVersion.of(17)) }
}

kotlin {
    compilerOptions { allWarningsAsErrors.set(true) }
}

// The one accessor it does NOT get is `libs`; this lookup is the same one the binary plugins use.
val libs = extensions.getByType<VersionCatalogsExtension>().named("libs")

dependencies {
    "testImplementation"(libs.findLibrary("junit").get())
}

tasks.withType<Test>().configureEach { useJUnitPlatform() }
registerGraphRuleCheck()   // a top-level Project extension in build-logic resolves here too
```

This is the only form `kotlin-platform.jvm.library` takes: it has no entry in `gradlePlugin { }`,
because a script plugin is registered by its file name. Writing both a class and a script for one id
is the one way to get two plugins that disagree.

Which form to take:

1. **Precompiled scripts first.** They read exactly like a module's own build file, so anyone who can
   edit a `build.gradle.kts` can edit one — which for four conventions is the whole job.
2. **Binary plugins once the conventions share code** — a helper both Android plugins call, a block
   applied only when another plugin is present (`pluginManager.withPlugin(...)`), or a plugin worth
   unit-testing with `ProjectBuilder`. Both forms may coexist; one id written half in each may not.

## The Version Catalog

```toml
# gradle/libs.versions.toml — every version in the build is in this file
[versions]
agp = "8.7.3"
kotlin = "2.2.0"
compose-bom = "2024.12.01"
coroutines = "1.9.0"
ktor = "3.0.3"
serialization = "1.7.3"
datetime = "0.6.2"
room = "2.7.1"
junit = "5.11.4"
turbine = "1.2.0"

[libraries]
# Plugin artifacts, for build-logic's compile classpath.
android-gradlePlugin = { module = "com.android.tools.build:gradle", version.ref = "agp" }
kotlin-gradlePlugin = { module = "org.jetbrains.kotlin:kotlin-gradle-plugin", version.ref = "kotlin" }
compose-gradlePlugin = { module = "org.jetbrains.kotlin:compose-compiler-gradle-plugin", version.ref = "kotlin" }

androidx-compose-bom = { module = "androidx.compose:compose-bom", version.ref = "compose-bom" }
androidx-compose-material3 = { module = "androidx.compose.material3:material3" }
androidx-lifecycle-viewmodel-compose = { module = "androidx.lifecycle:lifecycle-viewmodel-compose", version = "2.8.7" }
kotlinx-coroutines-core = { module = "org.jetbrains.kotlinx:kotlinx-coroutines-core", version.ref = "coroutines" }
kotlinx-coroutines-test = { module = "org.jetbrains.kotlinx:kotlinx-coroutines-test", version.ref = "coroutines" }
kotlinx-serialization-json = { module = "org.jetbrains.kotlinx:kotlinx-serialization-json", version.ref = "serialization" }
kotlinx-datetime = { module = "org.jetbrains.kotlinx:kotlinx-datetime", version.ref = "datetime" }
ktor-client-core = { module = "io.ktor:ktor-client-core", version.ref = "ktor" }
ktor-client-okhttp = { module = "io.ktor:ktor-client-okhttp", version.ref = "ktor" }
ktor-client-content-negotiation = { module = "io.ktor:ktor-client-content-negotiation", version.ref = "ktor" }
ktor-serialization-json = { module = "io.ktor:ktor-serialization-kotlinx-json", version.ref = "ktor" }
room-runtime = { module = "androidx.room:room-runtime", version.ref = "room" }
room-compiler = { module = "androidx.room:room-compiler", version.ref = "room" }
junit = { module = "org.junit.jupiter:junit-jupiter", version.ref = "junit" }
turbine = { module = "app.cash.turbine:turbine", version.ref = "turbine" }

[bundles]
# Artifacts that are always added together and always upgraded together: the client, an engine,
# and the serializer it negotiates content with. One of them alone does not make a working client.
ktor-client = ["ktor-client-core", "ktor-client-okhttp", "ktor-client-content-negotiation", "ktor-serialization-json"]

[plugins]
android-application = { id = "com.android.application", version.ref = "agp" }
android-library = { id = "com.android.library", version.ref = "agp" }
kotlin-android = { id = "org.jetbrains.kotlin.android", version.ref = "kotlin" }
kotlin-jvm = { id = "org.jetbrains.kotlin.jvm", version.ref = "kotlin" }
kotlin-serialization = { id = "org.jetbrains.kotlin.plugin.serialization", version.ref = "kotlin" }
ksp = { id = "com.google.devtools.ksp", version = "2.2.0-2.0.2" }
```

1. `androidx-compose-material3` carries no version on purpose: the BOM supplies it, and a version
   here would win over the BOM and silently defeat it. Accessors drop the dashes —
   `libs.kotlinx.coroutines.core`, `libs.bundles.ktor.client`, `alias(libs.plugins.kotlin.jvm)`.
2. A `[plugins]` entry is what `alias(...)` reads and cannot be used as a dependency; a `[libraries]`
   entry is the reverse. KSP versions carry the Kotlin version they were built against
   (`2.2.0-2.0.2`), so keep the pair adjacent in the file — upgrading one alone fails configuration.

## Module Build Files

Five files, one per archetype. What each one is *missing* is the design.

```kotlin
// :app/build.gradle.kts — the only module that names every other module
plugins { id("kotlin-platform.android.application") }

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
plugins { id("kotlin-platform.android.feature") }

android { namespace = "com.example.feature.orders" }

dependencies {
    implementation(project(":core:designsystem"))
    implementation(project(":core:model"))
    implementation(project(":api:orders"))
}
```

```kotlin
// :core:model/build.gradle.kts — no project(...) line exists, and that is the archetype
plugins { id("kotlin-platform.jvm.library") }

dependencies {
    api(libs.kotlinx.datetime)   // Instant appears in this module's own signatures
}
```

```kotlin
// :data:orders/build.gradle.kts — every framework in the build lands here
plugins {
    id("kotlin-platform.android.library")
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
}

android { namespace = "com.example.data.orders" }

dependencies {
    api(project(":api:orders"))         // this module hands back the contract's types
    implementation(project(":core:model"))
    implementation(libs.bundles.ktor.client)
    implementation(libs.room.runtime)
    ksp(libs.room.compiler)
}
```

```kotlin
// :api:orders/build.gradle.kts — interfaces and DTOs, and a build file to match
plugins {
    id("kotlin-platform.jvm.library")
    alias(libs.plugins.kotlin.serialization)
}

dependencies {
    // The plugin generates serializers; this is the runtime they call. @Serializable is on the
    // DTOs here, so the annotation and the format are part of the contract.
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

## Enforcing the Graph

One task per module, registered by the convention plugin, checking only that module's own
dependencies: nothing reads another project's state, and the rule survives the configuration cache.

```kotlin
// build-logic/src/main/kotlin/GraphRules.kt
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
    id("kotlin-platform.jvm.library")
    `java-test-fixtures`
}

dependencies {
    api(libs.kotlinx.datetime)
}
```

```kotlin
// :core:model src/testFixtures/kotlin/com/example/model/OrderFixtures.kt
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
