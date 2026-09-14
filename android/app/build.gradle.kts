import java.util.Properties

buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.google.gms:google-services:4.4.2")
        classpath("com.google.firebase:firebase-crashlytics-gradle:3.0.7")
    }
}

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// google-services.json is gitignored — apply plugins only when the file exists locally
val googleServicesJson = file("google-services.json")
if (googleServicesJson.exists()) {
    apply(plugin = "com.google.gms.google-services")
    apply(plugin = "com.google.firebase.crashlytics")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

// CI decodes the persistent keystore into a private temporary file. Local builds
// can keep using the gitignored key.properties file.
fun signingValue(property: String, environment: String): String? =
    System.getenv(environment)?.takeIf { it.isNotBlank() }
        ?: keystoreProperties.getProperty(property)?.takeIf { it.isNotBlank() }

val releaseKeyAlias = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")
val releaseStorePath = signingValue("storeFile", "ANDROID_KEYSTORE_FILE")
val releaseStorePassword = signingValue("storePassword", "ANDROID_STORE_PASSWORD")

// Do not silently use a debug key: it would make subsequent upgrades impossible.
gradle.taskGraph.whenReady {
    if (allTasks.any { it.project == project && it.name in setOf("validateSigningRelease", "validateSigningProfile") }) {
        check(listOf(releaseKeyAlias, releaseKeyPassword, releaseStorePath, releaseStorePassword).all { it != null }) {
            "Release/profile signing requires key.properties or ANDROID_KEYSTORE_FILE, ANDROID_STORE_PASSWORD, ANDROID_KEY_ALIAS and ANDROID_KEY_PASSWORD."
        }
        check(file(releaseStorePath!!).isFile) { "The configured release keystore is missing." }
    }
}

android {
    namespace = "com.keqdroid.keqdroid"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        // AGP 9 disables generated resource values unless explicitly enabled.
        resValues = true
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.caocaocc.keqdroid"
        resValue("string", "application_id", applicationId!!)
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // Только arm64-v8a: реальные Android-устройства. x86_64 был нерабочим
            // для VPN (в jniLibs не было ядер) — убран вместе с keqrnel.
            abiFilters += listOf("arm64-v8a")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            // `abiFilters` выше до чужих библиотек не достаёт: ML Kit из
            // mobile_scanner приносит libbarhopper_v3.so в AAR, и в APK
            // приезжали ВСЕ три её сборки — x86_64 на 5.9 МБ и armeabi-v7a на
            // 3.2 МБ поверх нужной arm64. Работать на этих архитектурах
            // приложению всё равно нечем: ядра собраны только под arm64.
            excludes += listOf(
                "**/x86/**",
                "**/x86_64/**",
                "**/armeabi-v7a/**",
            )
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = releaseKeyAlias
            keyPassword = releaseKeyPassword
            storeFile = releaseStorePath?.let { file(it) }
            storePassword = releaseStorePassword
        }
    }

    buildTypes {
        // Профильная сборка подписывается тем же ключом, что и релизная.
        //
        // Иначе её невозможно поставить поверх установленного релиза
        // (INSTALL_FAILED_UPDATE_INCOMPATIBLE), а единственный выход — удалить
        // приложение вместе со всеми подписками и настройками. Профилировать
        // приходится именно на реальном устройстве с реальными данными, так
        // что цена «чистой» отладочной подписи здесь — потерянный аккаунт.
        maybeCreate("profile").signingConfig = signingConfigs.getByName("release")

        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.profileinstaller:profileinstaller:1.4.1")
    implementation("androidx.activity:activity-ktx:1.9.3")
}
