import java.util.Properties

plugins {
  alias(libs.plugins.android.application)
}

val clientConfig = Properties().apply {
    val file = rootProject.file("agent-remote.properties")
    if (file.isFile) file.inputStream().use { load(it) }
}

fun clientConfigValue(key: String): String {
    val value = clientConfig.getProperty(key)
        ?: error("Missing '$key' in android/agent-remote.properties. Run configure-clients.ps1 with your server bundle first.")
    return "\"$value\""
}

android {
    namespace = "com.agentremote.app"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.agentremote.app"
        minSdk = 26
        targetSdk = 36
        versionCode = 6
        versionName = "1.5"
        buildConfigField("String", "GATEWAY_HOST", clientConfigValue("gatewayHost"))
        buildConfigField("String", "GATEWAY_ORIGIN", clientConfigValue("gatewayOrigin"))
        buildConfigField("String", "CONTROL_TOKEN", clientConfigValue("controlToken"))
        buildConfigField("String", "BOOTSTRAP_PASSWORD", clientConfigValue("bootstrapPassword"))
        buildConfigField("String", "BOOTSTRAP_FINGERPRINT", clientConfigValue("bootstrapFingerprint"))
    }

    val releaseStore = providers.environmentVariable("AGENT_REMOTE_ANDROID_KEYSTORE").orNull
    val releaseStorePassword = providers.environmentVariable("AGENT_REMOTE_ANDROID_STORE_PASSWORD").orNull
    val releaseKeyPassword = providers.environmentVariable("AGENT_REMOTE_ANDROID_KEY_PASSWORD").orNull
    signingConfigs {
        if (releaseStore != null && releaseStorePassword != null && releaseKeyPassword != null) {
            create("agentRemoteRelease") {
                storeFile = file(releaseStore)
                storePassword = releaseStorePassword
                keyAlias = "agent-remote"
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("agentRemoteRelease")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
      compose = false
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
  implementation(libs.androidx.core.ktx)
  implementation(libs.androidx.activity.ktx)
}
