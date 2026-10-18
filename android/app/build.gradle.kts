plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "fr.opcode.rtpdemo"
    compileSdk = 36

    defaultConfig {
        applicationId = "fr.opcode.rtpdemo"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    // Le cœur RTP vit dans le module React Native ; cette appli native sert de banc de test.
    sourceSets["main"].java.srcDir("../../rn-demo/modules/rtp-video/android/src/main/java/fr/opcode/rtpvideo/core")
}

// Aucune dépendance d'exécution : seulement les API Android (MediaCodec, sockets).
dependencies {
    testImplementation("junit:junit:4.13.2")
}
