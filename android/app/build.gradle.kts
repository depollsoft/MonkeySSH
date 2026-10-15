import com.android.build.api.dsl.ApplicationExtension
import java.util.Properties
import org.gradle.api.GradleException
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val requestedFlavorNames = gradle.startParameter.taskNames
    .joinToString(" ")
    .let { taskNames ->
        buildSet {
            if (taskNames.contains("Private", ignoreCase = true)) {
                add("private")
            }
            if (taskNames.contains("Production", ignoreCase = true)) {
                add("production")
            }
        }
    }
val firebaseConfigFlavorNames = requestedFlavorNames.ifEmpty {
    setOf("private", "production")
}
val hasGoogleServicesConfig =
    file("google-services.json").exists() ||
        firebaseConfigFlavorNames.any { flavor ->
            file("src/$flavor/google-services.json").exists()
        }
if (hasGoogleServicesConfig) {
    apply(plugin = "com.google.gms.google-services")
    apply(plugin = "com.google.firebase.crashlytics")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("app/key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

val requiredReleaseSigningProperties = listOf(
    "storePassword",
    "keyPassword",
    "keyAlias",
    "storeFile",
)
val missingReleaseSigningProperties = requiredReleaseSigningProperties.filter {
    keystoreProperties.getProperty(it).isNullOrBlank()
}
val releaseStoreFilePath = keystoreProperties.getProperty("storeFile")
    ?.takeIf { it.isNotBlank() }
val releaseStoreFile = releaseStoreFilePath?.let { file(it) }
val hasCompleteReleaseSigningConfig = keystorePropertiesFile.exists() &&
    missingReleaseSigningProperties.isEmpty() &&
    releaseStoreFile?.exists() == true
val allowUnsignedRelease = providers.environmentVariable("FLUTTY_ALLOW_UNSIGNED_RELEASE")
    .orElse("false")
    .map { it.equals("true", ignoreCase = true) }
    .get()
val isReleaseBuildRequested = gradle.startParameter.taskNames.any { taskName ->
    taskName.contains("Release", ignoreCase = true)
}

if (isReleaseBuildRequested && !allowUnsignedRelease) {
    when {
        !keystorePropertiesFile.exists() -> throw GradleException(
            "Release builds require Android signing configuration in android/app/key.properties. " +
                "Copy android/app/key.properties.example and provide a real release keystore, " +
                "or use a debug build for local development.",
        )
        missingReleaseSigningProperties.isNotEmpty() -> throw GradleException(
            "Release builds require complete Android signing configuration in android/app/key.properties. " +
                "Missing: ${missingReleaseSigningProperties.joinToString(", ")}.",
        )
        releaseStoreFile?.exists() != true -> throw GradleException(
            "Release builds require a valid Android keystore. " +
                "Configured storeFile '${releaseStoreFilePath ?: "(missing)"}' was not found.",
        )
    }
}

extensions.configure<ApplicationExtension>("android") {
    namespace = "xyz.depollsoft.monkeyssh"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    buildFeatures {
        resValues = true
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    signingConfigs {
        if (hasCompleteReleaseSigningConfig && releaseStoreFile != null) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = releaseStoreFile
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    defaultConfig {
        applicationId = "xyz.depollsoft.monkeyssh"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "environment"

    productFlavors {
        create("private") {
            dimension = "environment"
            applicationIdSuffix = ".private"
            resValue("string", "app_name", "MonkeySSH β")
        }
        create("production") {
            dimension = "environment"
            resValue("string", "app_name", "MonkeySSH")
        }
    }

    buildTypes {
        release {
            if (hasCompleteReleaseSigningConfig) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

flutter {
    source = "../.."
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.fromTarget(JavaVersion.VERSION_17.toString())
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("eu.simonbinder:sqlite3-native-library:3.52.0")
    // BiometricPrompt for per-use hardware SSH key confirmation.
    implementation("androidx.biometric:biometric:1.1.0")
}
