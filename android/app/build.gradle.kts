plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

// The commit this APK is built from. The core in jniLibs comes from the same
// commit (CI, plan A3), so the app can compare it with `libspdhost.so caps`
// build_sha. Outside git (or with git missing) it is "unknown".
val gitSha: String = runCatching {
    providers.exec {
        commandLine("git", "rev-parse", "HEAD")
        isIgnoreExitValue = true
    }.standardOutput.asText.get().trim()
}.getOrDefault("").let { if (Regex("[0-9a-f]{40}").matches(it)) it else "unknown" }

android {
    namespace = "io.github.seuj09.spdhost"
    compileSdk = 35
    buildToolsVersion = "35.0.0"

    defaultConfig {
        applicationId = "io.github.seuj09.spdhost"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0-p1"
        buildConfigField("String", "GIT_SHA", "\"$gitSha\"")
        ndk {
            // The two ABIs `make cross` builds (plan §3, §7). No x86: the
            // static core exists only for ARM.
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    buildTypes {
        debug {
            // Debug signing only (the default debug keystore). No release
            // signing config lives in this repo.
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            isMinifyEnabled = false
        }
    }

    packaging {
        jniLibs {
            // libspdhost.so is a static executable, not a JNI library. It must
            // be extracted to nativeLibraryDir (extractNativeLibs=true) so it
            // can be exec'd from there; it is never exec'd from filesDir.
            useLegacyPackaging = true
            // Ship the exact `make cross` bytes (same sha256 as the zips):
            // never let AGP strip it.
            keepDebugSymbols += "**/libspdhost.so"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    testOptions {
        unitTests.all {
            // Tests read src/main files (manifest, device_filter.xml,
            // sources) relative to the module dir.
            it.workingDir = projectDir
        }
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    debugImplementation(libs.androidx.compose.ui.tooling)

    testImplementation(libs.junit)
}
