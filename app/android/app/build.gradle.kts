plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.call"
    compileSdk = 36 // Required by your jni video call plugins
    ndkVersion = "28.2.13676358" // Matches plugin requirement for backward compatibility

    defaultConfig {
        applicationId = "com.example.call"
        minSdk = flutter.minSdkVersion // Safe minimum for Android 10 support
        targetSdk = 34
        versionCode = 1
        versionName = "1.0.0"
        multiDexEnabled = true
    }

    compileOptions {
        // Enforce Core Library Desugaring for local notifications compatibility
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug") 
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

dependencies {
    implementation("org.jetbrains.kotlin:kotlin-stdlib:1.8.22")
    // Native desugaring library dependency
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.3")
}
