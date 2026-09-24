plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.openapi.generator)
}

// The same generator settings net-openapi teaches, over the spec its samples call.
val generated = layout.buildDirectory.dir("generated/openapi")

openApiGenerate {
    generatorName.set("kotlin")
    library.set("jvm-retrofit2")
    inputSpec.set("$projectDir/specs/orders.yaml")
    outputDir.set(generated)
    packageName.set("com.example.api.generated")
    apiPackage.set("com.example.api.generated.api")
    modelPackage.set("com.example.api.generated.model")
    generateApiTests.set(false)
    generateModelTests.set(false)
    configOptions.set(
        mapOf("serializationLibrary" to "kotlinx_serialization", "useCoroutines" to "true", "nonPublicApi" to "true"),
    )
}

kotlin.sourceSets["main"].kotlin.srcDir(generated.map { it.dir("src/main/kotlin") })
tasks.compileKotlin { dependsOn(tasks.openApiGenerate) }

// scripts/compile-snippets.sh passes the emitted units; without them the module is empty.
providers.gradleProperty("snippets.units").orNull?.let { units ->
    kotlin.sourceSets["main"].kotlin.srcDir("$units/net/main")
    kotlin.sourceSets["test"].kotlin.srcDir("$units/net/test")
}

dependencies {
    implementation(libs.okhttp)
    implementation(libs.okhttp.logging.interceptor)
    implementation(libs.retrofit)
    implementation(libs.retrofit.converter.kotlinx.serialization)
    implementation(libs.retrofit.converter.scalars)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.core)
    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testImplementation(libs.kotlin.test)
    testImplementation(libs.okhttp.mockwebserver)
    testImplementation(libs.kotlinx.coroutines.test)
}

tasks.test { useJUnitPlatform() }
