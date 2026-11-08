import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

val releaseProperties = Properties().apply {
    rootProject.file("release.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}

// versionCode = major * 10000 + minor * 100 + build, so every build of every
// version sorts after the one before it; bump-version.sh rewrites these two.
val appVersionName = "2.1"
val appBuild = 1
val appVersionCode = appVersionName.split(".").let { parts ->
    parts[0].toInt() * 10000 + parts.getOrElse(1) { "0" }.toInt() * 100 + appBuild
}

android {
    namespace = "com.romangarms.autoxlive"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.romangarms.autoxlive"
        minSdk = 26
        targetSdk = 37
        versionCode = appVersionCode
        versionName = appVersionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "BASE_URL", "\"https://autox.romangarms.com\"")
    }

    signingConfigs {
        create("release") {
            releaseProperties.getProperty("storeFile")?.let { storeFile = rootProject.file(it) }
            storePassword = releaseProperties.getProperty("storePassword")
            keyAlias = releaseProperties.getProperty("keyAlias")
            keyPassword = releaseProperties.getProperty("keyPassword")
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            val devURL = (project.findProperty("autoxDevBaseUrl") as String?) ?: "http://10.0.2.2:8321"
            buildConfigField("String", "BASE_URL", "\"$devURL\"")
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (releaseProperties.getProperty("storeFile") != null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.core.ktx)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.lifecycle.process)
    implementation(libs.navigation.compose)
    implementation(libs.datastore.preferences)
    implementation(libs.serialization.json)
    implementation(libs.retrofit)
    implementation(libs.retrofit.serialization)
    implementation(libs.okhttp)
    debugImplementation(libs.compose.ui.tooling)

    testImplementation(libs.junit)
    testImplementation(libs.coroutines.test)
    testImplementation(libs.okhttp.mockwebserver)
}
