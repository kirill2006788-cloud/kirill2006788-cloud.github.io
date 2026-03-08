 import java.util.Properties
 import java.io.File

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

fun loadLocalSecrets(file: File): Properties {
    val props = Properties()
    if (!file.exists()) return props

    val bytes = file.readBytes()
    if (bytes.isEmpty()) return props

    val (charset, startOffset) = when {
        bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte() -> Charsets.UTF_16LE to 2
        bytes.size >= 2 && bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte() -> Charsets.UTF_16BE to 2
        bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte() -> Charsets.UTF_8 to 3
        else -> Charsets.UTF_8 to 0
    }

    val text = bytes.copyOfRange(startOffset, bytes.size).toString(charset)
    text.reader().use { props.load(it) }
    return props
}

val secretsFile = rootProject.file("secrets.properties")
val secrets = loadLocalSecrets(secretsFile)
val releaseKeyFile = rootProject.file("key.properties")
val releaseKeyProperties = loadLocalSecrets(releaseKeyFile)
val releaseSigningReady = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    .all { !releaseKeyProperties.getProperty(it).isNullOrBlank() }
val isReleaseTask = gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }

if (isReleaseTask && !releaseSigningReady) {
    throw GradleException(
        "Release signing is not configured. Create android/key.properties with storeFile, storePassword, keyAlias, keyPassword."
    )
}

val yandexMapsKey = (secrets.getProperty("YANDEX_MAPS_KEY")
    ?: secrets.getProperty("\uFEFFYANDEX_MAPS_KEY")
    ?: System.getenv("YANDEX_MAPS_KEY")
    ?: "")

if (yandexMapsKey.isBlank()) {
    throw GradleException("YANDEX_MAPS_KEY is not set. Provide it in android/secrets.properties (UTF-8) or via environment variable YANDEX_MAPS_KEY.")
}

android {
    namespace = "ru.prostotaxi.client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    signingConfigs {
        if (releaseSigningReady) {
            create("release") {
                storeFile = file(releaseKeyProperties.getProperty("storeFile"))
                storePassword = releaseKeyProperties.getProperty("storePassword")
                keyAlias = releaseKeyProperties.getProperty("keyAlias")
                keyPassword = releaseKeyProperties.getProperty("keyPassword")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "ru.prostotaxi.client"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        manifestPlaceholders["applicationName"] = "ru.prostotaxi.client.MainApplication"
        manifestPlaceholders["YANDEX_MAPS_KEY"] = yandexMapsKey

        buildConfigField("String", "YANDEX_MAPS_KEY", "\"$yandexMapsKey\"")
        
        resValue("string", "app_name", "Трезвый водитель Ноль Промилле")
    }

    buildFeatures {
        buildConfig = true
    }

    packaging {
        jniLibs {
            // Some bundled native libraries fail symbol stripping on Windows/CI.
            keepDebugSymbols += setOf("**/*.so")
        }
    }

    buildTypes {
        release {
            // Use a real release key when `android/key.properties` is present.
            signingConfig = if (releaseSigningReady) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
