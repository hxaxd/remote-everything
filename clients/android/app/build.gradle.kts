plugins {
  alias(libs.plugins.android.application)
  alias(libs.plugins.compose.compiler)
}

android {
    namespace = "com.remoteeverything.app"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.remoteeverything.app"
        minSdk = 26
        targetSdk = 36
        versionCode = 15
        versionName = "3.0.0"
    }

    val releaseStore = providers.environmentVariable("REMOTE_EVERYTHING_ANDROID_KEYSTORE").orNull
    val releaseStorePassword = providers.environmentVariable("REMOTE_EVERYTHING_ANDROID_STORE_PASSWORD").orNull
    val releaseKeyPassword = providers.environmentVariable("REMOTE_EVERYTHING_ANDROID_KEY_PASSWORD").orNull
    signingConfigs {
        if (releaseStore != null && releaseStorePassword != null && releaseKeyPassword != null) {
            create("remoteEverythingRelease") {
                storeFile = file(releaseStore)
                storePassword = releaseStorePassword
                keyAlias = "agent-remote"
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("remoteEverythingRelease")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
      compose = true
      aidl = false
      buildConfig = true
      shaders = false
    }

    packaging {
      resources {
        excludes += "/META-INF/{AL2.0,LGPL2.1}"
      }
    }
}

kotlin {
    jvmToolchain(17)
}

dependencies {
  implementation(platform(libs.compose.bom))
  implementation(libs.androidx.core.ktx)
  implementation(libs.androidx.activity.compose)
  implementation(libs.compose.ui)
  implementation(libs.compose.ui.tooling.preview)
  implementation(libs.compose.material3)
  implementation(libs.compose.material.icons)
  implementation(libs.navigation.compose)
  implementation(libs.lifecycle.viewmodel.compose)
  implementation(libs.lifecycle.runtime.compose)
  implementation(libs.kotlinx.coroutines.android)
  implementation(libs.zxing.embedded)
  debugImplementation(libs.compose.ui.tooling)
  testImplementation(libs.junit)
  testImplementation(libs.json)
}
