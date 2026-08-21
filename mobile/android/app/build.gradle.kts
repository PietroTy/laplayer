plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.chaquo.python")
}

android {
    namespace = "com.example.localify"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // Migrated from deprecated kotlinOptions.jvmTarget to compilerOptions DSL (Kotlin 2.2+)
    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    defaultConfig {
        applicationId = "com.example.localify"
        minSdk = 24
        targetSdk = 34
        versionCode = 5
        versionName = "2.0.1"

        ndk {
            abiFilters.clear()
            abiFilters.addAll(listOf("arm64-v8a", "armeabi-v7a", "x86_64", "x86"))
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

chaquopy {
    defaultConfig {
        pip {
            options("--extra-index-url", "https://pypi.org/simple")
            options("--no-deps")
            // librespot sem resolver deps automaticamente (zeroconf>=0.146 não existe p/ Android)
            // deps manuais listadas no requirements.txt
            install("-r", "requirements.txt")
        }
    }
}

flutter {
    source = "../.."
}
