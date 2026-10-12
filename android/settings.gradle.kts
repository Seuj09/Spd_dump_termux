// spdhost Android front-end (plan P1). One module, :app. The native core is
// not built here: CI copies the `make cross` binaries from no-root/ into
// app/src/main/jniLibs/<abi>/libspdhost.so before Gradle runs.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "spdhost-android"
include(":app")
