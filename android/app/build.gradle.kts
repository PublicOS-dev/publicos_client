import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.publicos.dev"
    compileSdk = 36 /*flutter.compileSdkVersion*/
    ndkVersion = "27.0.12077973"

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.publicos.dev"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        // debug {
        //     applicationIdSuffix = ".debug"
        // }
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
    // Social push token: MainActivity initialises a
    // secondary FirebaseApp for the second project and asks its
    // FirebaseMessaging for a token. The firebase_messaging plugin brings the
    // same artifacts transitively; naming them here makes the app's own Kotlin
    // compile against them regardless of how the plugin scopes its deps.
    implementation(platform("com.google.firebase:firebase-bom:34.13.0"))
    implementation("com.google.firebase:firebase-messaging")
    // media3 (ExoPlayer) at the current stable release. video_player_android
    // 2.12.2 pins 1.9.2; naming the same five modules here at a newer version
    // makes Gradle resolve the plugin's requests up to it (highest version
    // wins). 1.11.0 carries the two fixes for the loop / seek stall seen on the
    // Pixel 8 Pro with ffmpeg exports that have an edit list off a keyframe:
    // "codec swallowing all samples
    // if previously flushed before receiving input buffers" and "an
    // unnecessary reset when joining tracks with pre-roll samples". Keep the
    // list in step with the plugin's android/build.gradle.kts.
    val media3Version = "1.11.1"
    implementation("androidx.media3:media3-exoplayer:$media3Version")
    implementation("androidx.media3:media3-exoplayer-hls:$media3Version")
    implementation("androidx.media3:media3-exoplayer-dash:$media3Version")
    implementation("androidx.media3:media3-exoplayer-rtsp:$media3Version")
    implementation("androidx.media3:media3-exoplayer-smoothstreaming:$media3Version")
}
