group = "com.ble_mesh.ble_mesh"
version = "1.0-SNAPSHOT"

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

val agpMajor =
    com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION
        .substringBefore('.')
        .toInt()

// Support both legacy KGP (AGP < 9) and Built-in Kotlin (AGP >= 9).
if (agpMajor < 9) {
    apply(plugin = "org.jetbrains.kotlin.android")
}

android {
    namespace = "com.ble_mesh.ble_mesh"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") { java.srcDirs("src/main/kotlin") }
        getByName("test") { java.srcDirs("src/test/kotlin") }
    }

    defaultConfig {
        // BLE Mesh 需要 Android 5.0 (API 21) 以上；API 24+ 获得更完整的 BLE 支持
        minSdk = 24
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()
                it.outputs.upToDateWhen { false }
                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

project.extensions.configure(
    org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension::class.java,
) {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    // Kotlin 协程（异步 BLE 操作）
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // Nordic nRF Mesh Library（真实 BLE Mesh 协议栈）
    // Maven Central 正式 artifact 名为 "mesh"（非旧版 mesh-provisioner）
    // https://central.sonatype.com/artifact/no.nordicsemi.android/mesh
    implementation("no.nordicsemi.android:mesh:3.3.7")

    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
