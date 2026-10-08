import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.strata"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.strata.app"
        // Phase D: flutter_secure_storage requires API 23+ for the encrypted
        // SharedPreferences code path that backs the keystore-protected wallet
        // mnemonic on Android. Lower API levels use a less secure fallback.
        minSdk = flutter.minSdkVersion
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    val keystoreProps = rootProject.file("key.properties")
    val releaseSigning = if (keystoreProps.exists()) {
        val p = Properties().apply { load(FileInputStream(keystoreProps)) }
        signingConfigs.create("release") {
            keyAlias = p.getProperty("keyAlias")
            keyPassword = p.getProperty("keyPassword")
            storeFile = rootProject.file(p.getProperty("storeFile")!!)
            storePassword = p.getProperty("storePassword")
        }
        signingConfigs.getByName("release")
    } else null

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            signingConfig = releaseSigning ?: signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}
